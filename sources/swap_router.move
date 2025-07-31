#[allow(unused_variable, unused_use, duplicate_alias, deprecated_usage, unused_const, unused_function, unused_trailing_semi, unused_assignment)]
module clmm::swap_router {
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::dynamic_object_field as dof;
    use sui::table::{Self, Table};
    use sui::transfer;
    use std::type_name::{Self, TypeName};
    use std::vector;
    use std::option::{Self, Option};
    use clmm::clmm::{Self, LiquidityPool, PoolRegistry, PoolInfo, TypePair, create_type_pair, get_type_pair_token_x, get_type_pair_token_y, get_pool_info};

    // Error codes
    const EInvalidPath: u64 = 11;
    const EPoolNotFound: u64 = 12;
    const ENoValidPools: u64 = 13;
    const EInsufficientOutput: u64 = 14;
    const EInvalidPathLength: u64 = 15;
    const EInvalidAmount: u64 = 1;
    const ENoPathFound: u64 = 16;
    const EPathTooLong: u64 = 17;
    const EInvalidAllocation: u64 = 18;

    // SwapRouter struct
    public struct SwapRouter has key {
        id: UID,
    }

    // Allocation for a single pool
    public struct PoolAllocation has copy, drop, store {
        pool_addr: address,
        amount_in: u64,
        expected_out: u64,
        fee_rate: u64,
        is_x_to_y: bool, // Indicates swap direction
    }

    // Path allocation for a multi-hop route
    public struct PathAllocation has copy, drop, store {
        token_types: vector<TypeName>,
        pool_allocations: vector<PoolAllocation>,
        amount_in: u64,
        expected_out: u64,
        proportion: u64, // Percentage (0-10000 basis points)
    }

    // Swap route for frontend display
    public struct SwapRoute has copy, drop, store {
        paths: vector<PathAllocation>,
        total_in: u64,
        total_out: u64,
    }

    // Pool output struct
    public struct PoolOutput has copy, drop, store {
        pool_addr: address,
        output: u64,
        reserve_x: u64,
    }

    // Path output struct for allocation optimization
    public struct PathOutput has copy, drop, store {
        token_types: vector<TypeName>,
        amount_in: u64,
        pool_allocations: vector<PoolAllocation>,
    }

    // SwapPath object for storing user-defined paths
    public struct SwapPath has key, store {
        id: UID,
        token_types: vector<TypeName>,
        pool_addrs: vector<address>,
        type_pairs: vector<TypePair>, // Store TypePair for each hop
    }

    // Initialize SwapRouter
    fun init(ctx: &mut TxContext) {
        let router = SwapRouter {
            id: object::new(ctx),
        };
        transfer::share_object(router);
    }

    // Create swap path object
    public fun create_swap_path(
        token_types: vector<TypeName>,
        pool_addrs: vector<address>,
        type_pairs: vector<TypePair>,
        ctx: &mut TxContext
    ): SwapPath {
        assert!(vector::length(&token_types) >= 2, EInvalidPathLength);
        assert!(vector::length(&token_types) == vector::length(&pool_addrs) + 1, EInvalidPath);
        assert!(vector::length(&pool_addrs) == vector::length(&type_pairs), EInvalidPath);
        SwapPath {
            id: object::new(ctx),
            token_types,
            pool_addrs,
            type_pairs,
        }
    }

    // Estimate output for a single pool swap (X to Y)
    public fun estimate_swap_x_to_y<X, Y>(
        pool: &LiquidityPool<X, Y>,
        amount_in: u64
    ): u64 {
        let (reserve_x, reserve_y, fee_rate, _, _, _) = clmm::get_pool_info<X, Y>(pool);
        if (reserve_x == 0 || reserve_y == 0) return 0;

        let amount_in_with_fee = (amount_in as u128) * ((10000 - fee_rate) as u128);
        let amount_out = (amount_in_with_fee * (reserve_y as u128)) / (((reserve_x as u128) * (10000 as u128)) + amount_in_with_fee);
        (amount_out as u64)
    }

    // Estimate output for a single pool swap (Y to X)
    public fun estimate_swap_y_to_x<X, Y>(
        pool: &LiquidityPool<X, Y>,
        amount_in: u64
    ): u64 {
        let (reserve_x, reserve_y, fee_rate, _, _, _) = clmm::get_pool_info<X, Y>(pool);
        if (reserve_x == 0 || reserve_y == 0) return 0;

        let amount_in_with_fee = (amount_in as u128) * ((10000 - fee_rate) as u128);
        let amount_out = (amount_in_with_fee * (reserve_x as u128)) / (((reserve_y as u128) * (10000 as u128)) + amount_in_with_fee);
        (amount_out as u64)
    }

    // Estimate output for a pool using PoolInfo (for dynamic types)
    fun estimate_pool_output(
        registry: &PoolRegistry,
        type_pair: &TypePair,
        pool_addr: address,
        amount_in: u64,
        is_x_to_y: bool
    ): (u64, u64) {
        let pools = table::borrow(clmm::get_pools(registry), *type_pair);
        let mut i = 0;
        let mut output = 0;
        let mut fee_rate = 0;
        while (i < vector::length(pools)) {
            let pool_info = vector::borrow(pools, i);
            if (clmm::get_pool_addr(pool_info) == pool_addr) {
                // Use dynamic object field to borrow the LiquidityPool
                let pool = dof::borrow<address, LiquidityPool<TypeName, TypeName>>(clmm::get_registry_id(registry), pool_addr);
                let (reserve_x, reserve_y, pool_fee_rate, _, _, _) = clmm::get_pool_info(pool);
                fee_rate = pool_fee_rate;
                if (reserve_x == 0 || reserve_y == 0) {
                    return (0, fee_rate)
                };
                let amount_in_with_fee = (amount_in as u128) * ((10000 - fee_rate) as u128);
                output = if (is_x_to_y) {
                    ((amount_in_with_fee * (reserve_y as u128)) / (((reserve_x as u128) * (10000 as u128)) + amount_in_with_fee)) as u64
                } else {
                    ((amount_in_with_fee * (reserve_x as u128)) / (((reserve_y as u128) * (10000 as u128)) + amount_in_with_fee)) as u64
                };
                return (output, fee_rate)
            };
            i = i + 1;
        };
        (0, fee_rate)
    }

    // Find all possible paths using BFS (max 3 hops)
    public fun find_paths(
        registry: &PoolRegistry,
        token_in: TypeName,
        token_out: TypeName,
        max_hops: u64
    ): vector<vector<TypeName>> {
        assert!(max_hops <= 3, EPathTooLong);
        let mut paths = vector::empty<vector<TypeName>>();
        let mut queue = vector::empty<vector<TypeName>>();
        vector::push_back(&mut queue, vector::singleton(token_in));
        let mut visited = vector::singleton(token_in);
        let type_pairs = clmm::get_type_pairs(registry);

        while (!vector::is_empty(&queue)) {
            let current_path = vector::pop_back(&mut queue);
            let current_token = *vector::borrow(&current_path, vector::length(&current_path) - 1);

            if (current_token == token_out && vector::length(&current_path) > 1) {
                vector::push_back(&mut paths, current_path);
                continue
            };

            if (vector::length(&current_path) > max_hops) {
                continue
            };

            let mut i = 0;
            while (i < vector::length(&type_pairs)) {
                let pair = vector::borrow(&type_pairs, i);
                let token_x = get_type_pair_token_x(pair);
                let token_y = get_type_pair_token_y(pair);

                if (token_x == current_token && !vector::contains(&visited, &token_y)) {
                    let mut new_path = current_path;
                    vector::push_back(&mut new_path, token_y);
                    if (table::contains(clmm::get_pools(registry), *pair)) {
                        vector::push_back(&mut queue, new_path);
                        vector::push_back(&mut visited, token_y);
                    };
                } else if (token_y == current_token && !vector::contains(&visited, &token_x)) {
                    let mut new_path = current_path;
                    vector::push_back(&mut new_path, token_x);
                    if (table::contains(clmm::get_pools(registry), *pair)) {
                        vector::push_back(&mut queue, new_path);
                        vector::push_back(&mut visited, token_x);
                    };
                };
                i = i + 1;
            };
        };
        paths
    }

    // Optimize volume allocation across pools for a single hop
    fun allocate_across_pools<X, Y>(
        registry: &PoolRegistry,
        amount_in: u64
    ): vector<PoolAllocation> {
        let type_pair = create_type_pair<X, Y>();
        if (!table::contains(clmm::get_pools(registry), type_pair)) {
            return vector::empty<PoolAllocation>()
        };
        let pools = table::borrow(clmm::get_pools(registry), type_pair);
        let mut allocations = vector::empty<PoolAllocation>();
        let mut remaining_amount = amount_in;

        let mut pool_outputs = vector::empty<PoolOutput>();
        let mut i = 0;
        while (i < vector::length(pools)) {
            let pool_info: &PoolInfo = vector::borrow(pools, i);
            let pool = dof::borrow<address, LiquidityPool<X, Y>>(clmm::get_registry_id(registry), clmm::get_pool_addr(pool_info));
            let output = estimate_swap_x_to_y(pool, remaining_amount / vector::length(pools));
            if (output > 0) {
                let (reserve_x, _, _, _, _, _) = clmm::get_pool_info(pool);
                vector::push_back(&mut pool_outputs, PoolOutput {
                    pool_addr: clmm::get_pool_addr(pool_info),
                    output,
                    reserve_x,
                });
            };
            i = i + 1;
        };

        while (remaining_amount > 0 && !vector::is_empty(&pool_outputs)) {
            let mut best_pool_idx = 0;
            let mut best_output_per_unit = 0;
            let mut best_pool_addr = @0x0;
            let mut best_fee_rate = 0;
            i = 0;

            while (i < vector::length(&pool_outputs)) {
                let pool_output = *vector::borrow(&pool_outputs, i);
                let pool = dof::borrow<address, LiquidityPool<X, Y>>(clmm::get_registry_id(registry), pool_output.pool_addr);
                let test_amount = if (remaining_amount > 1000) 1000 else remaining_amount;
                let output = estimate_swap_x_to_y(pool, test_amount);
                let output_per_unit = if (test_amount > 0) output / test_amount else 0;
                let (_, _, fee_rate, _, _, _) = clmm::get_pool_info(pool);
                if (output_per_unit > best_output_per_unit || (output_per_unit == best_output_per_unit && fee_rate < best_fee_rate)) {
                    best_output_per_unit = output_per_unit;
                    best_pool_idx = i;
                    best_pool_addr = pool_output.pool_addr;
                    best_fee_rate = fee_rate;
                };
                i = i + 1;
            };

            if (best_output_per_unit == 0) break;

            let pool = dof::borrow<address, LiquidityPool<X, Y>>(clmm::get_registry_id(registry), best_pool_addr);
            let alloc_amount = if (remaining_amount > 1000000) 1000000 else remaining_amount;
            let expected_out = estimate_swap_x_to_y(pool, alloc_amount);
            if (expected_out > 0) {
                vector::push_back(&mut allocations, PoolAllocation {
                    pool_addr: best_pool_addr,
                    amount_in: alloc_amount,
                    expected_out,
                    fee_rate: best_fee_rate,
                    is_x_to_y: true,
                });
                remaining_amount = if (remaining_amount > alloc_amount) remaining_amount - alloc_amount else 0;
            };
            vector::remove(&mut pool_outputs, best_pool_idx);
        };

        allocations
    }

    // Estimate output for a multi-hop path
    fun estimate_path_output<X, Y>(
        registry: &PoolRegistry,
        amount_in: u64
    ): (u64, vector<PoolAllocation>) {
        let type_pair = create_type_pair<X, Y>();
        if (!table::contains(clmm::get_pools(registry), type_pair)) {
            return (0, vector::empty<PoolAllocation>())
        };
        let pools = table::borrow(clmm::get_pools(registry), type_pair);
        let mut pool_allocations = vector::empty<PoolAllocation>();
        let mut max_output = 0;
        let mut best_pool_addr = @0x0;
        let mut best_fee_rate = 0;
        let mut j = 0;
        while (j < vector::length(pools)) {
            let pool_info = vector::borrow(pools, j);
            let pool = dof::borrow<address, LiquidityPool<X, Y>>(clmm::get_registry_id(registry), clmm::get_pool_addr(pool_info));
            let output = estimate_swap_x_to_y(pool, amount_in);
            if (output > max_output) {
                max_output = output;
                best_pool_addr = clmm::get_pool_addr(pool_info);
                best_fee_rate = clmm::get_pool_info_fee_rate(pool_info);
            };
            j = j + 1;
        };
        if (max_output == 0) {
            return (0, vector::empty<PoolAllocation>())
        };
        vector::push_back(&mut pool_allocations, PoolAllocation {
            pool_addr: best_pool_addr,
            amount_in: amount_in,
            expected_out: max_output,
            fee_rate: best_fee_rate,
            is_x_to_y: true,
        });
        (max_output, pool_allocations)
    }

    // Estimate output for a multi-hop path dynamically
    fun estimate_path_output_dynamic(
        registry: &PoolRegistry,
        path: &vector<TypeName>,
        type_pairs: &vector<TypePair>,
        amount_in: u64
    ): (u64, vector<PoolAllocation>) {
        let mut total_out = amount_in;
        let mut all_allocations = vector::empty<PoolAllocation>();
        let mut i = 0;
        while (i < vector::length(path) - 1) {
            let type_pair = *vector::borrow(type_pairs, i);
            if (!table::contains(clmm::get_pools(registry), type_pair)) {
                return (0, vector::empty<PoolAllocation>())
            };
            let pools = table::borrow(clmm::get_pools(registry), type_pair);
            let mut max_output = 0;
            let mut best_pool_addr = @0x0;
            let mut best_fee_rate = 0;
            let mut is_x_to_y = false;
            let token_x = get_type_pair_token_x(&type_pair);
            let token_y = get_type_pair_token_y(&type_pair);
            let current_token = *vector::borrow(path, i);
            let next_token = *vector::borrow(path, i + 1);
            let mut j = 0;
            while (j < vector::length(pools)) {
                let pool_info = vector::borrow(pools, j);
                let pool_addr = clmm::get_pool_addr(pool_info);
                let (output, fee_rate) = estimate_pool_output(registry, &type_pair, pool_addr, total_out, current_token == token_x && next_token == token_y);
                if (output > max_output) {
                    max_output = output;
                    best_pool_addr = pool_addr;
                    best_fee_rate = fee_rate;
                    is_x_to_y = current_token == token_x && next_token == token_y;
                };
                j = j + 1;
            };
            if (max_output == 0) {
                return (0, vector::empty<PoolAllocation>())
            };
            vector::push_back(&mut all_allocations, PoolAllocation {
                pool_addr: best_pool_addr,
                amount_in: total_out,
                expected_out: max_output,
                fee_rate: best_fee_rate,
                is_x_to_y,
            });
            total_out = max_output;
            i = i + 1;
        };
        (total_out, all_allocations)
    }

    // Estimate multi-path swap with optimized allocations
    public fun estimate_multi_path_swap(
        registry: &PoolRegistry,
        token_in: TypeName,
        token_out: TypeName,
        amount_in: u64
    ): SwapRoute {
        let paths = find_paths(registry, token_in, token_out, 3);
        if (vector::is_empty(&paths)) {
            return SwapRoute {
                paths: vector::empty(),
                total_in: amount_in,
                total_out: 0,
            }
        };

        let mut path_allocations = vector::empty<PathAllocation>();
        let mut total_out = 0;
        let mut remaining_amount = amount_in;
        let max_paths = if (vector::length(&paths) > 5) 5 else vector::length(&paths); // Limit to 5 paths for gas efficiency
        let mut i = 0;

        // Initial allocation: distribute equally
        let mut path_outputs = vector::empty<PathOutput>();
        while (i < max_paths) {
            let path = *vector::borrow(&paths, i);
            let type_pairs = vector::empty<TypePair>();
            let mut j = 0;
            while (j < vector::length(&path) - 1) {
                let current_token = *vector::borrow(&path, j);
                let next_token = *vector::borrow(&path, j + 1);
                let mut type_pair_opt = option::none<TypePair>();
                let mut type_pairs = clmm::get_type_pairs(registry);
                let mut k = 0;
                while (k < vector::length(&type_pairs)) {
                    let pair = *vector::borrow(&type_pairs, k);
                    let token_x = get_type_pair_token_x(&pair);
                    let token_y = get_type_pair_token_y(&pair);
                    if ((current_token == token_x && next_token == token_y) || 
                        (current_token == token_y && next_token == token_x)) {
                        type_pair_opt = option::some(pair);
                        break
                    };
                    k = k + 1;
                };
                if (option::is_none(&type_pair_opt)) {
                    break
                };
                vector::push_back(&mut type_pairs, option::extract(&mut type_pair_opt));
                j = j + 1;
            };
            if (vector::length(&type_pairs) == vector::length(&path) - 1) {
                let (output, allocations) = estimate_path_output_dynamic(registry, &path, &type_pairs, amount_in / max_paths);
                if (output > 0) {
                    vector::push_back(&mut path_outputs, PathOutput {
                        token_types: path,
                        amount_in: amount_in / max_paths,
                        pool_allocations: allocations,
                    });
                };
            };
            i = i + 1;
        };

        if (vector::is_empty(&path_outputs)) {
            return SwapRoute {
                paths: vector::empty(),
                total_in: amount_in,
                total_out: 0,
            }
        };

        // Optimize allocations iteratively
        let mut best_allocations = vector::empty<PathOutput>();
        let mut best_total_out = 0;
        let step = amount_in / 10; // Incremental step for allocation
        let mut iteration = 0;
        let max_iterations = 10; // Limit iterations for gas efficiency

        while (iteration < max_iterations && remaining_amount > 0) {
            let mut current_allocations = vector::empty<PathOutput>();
            let mut current_total_out = 0;
            i = 0;
            while (i < vector::length(&path_outputs)) {
                let path_output = *vector::borrow(&path_outputs, i);
                let alloc_amount = if (remaining_amount > step) step else remaining_amount;
                let type_pairs = vector::empty<TypePair>();
                let mut j = 0;
                while (j < vector::length(&path_output.token_types) - 1) {
                    let current_token = *vector::borrow(&path_output.token_types, j);
                    let next_token = *vector::borrow(&path_output.token_types, j + 1);
                    let mut type_pair_opt = option::none<TypePair>();
                    let mut type_pairs = clmm::get_type_pairs(registry);
                    let mut k = 0;
                    while (k < vector::length(&type_pairs)) {
                        let pair = *vector::borrow(&type_pairs, k);
                        let token_x = get_type_pair_token_x(&pair);
                        let token_y = get_type_pair_token_y(&pair);
                        if ((current_token == token_x && next_token == token_y) || 
                            (current_token == token_y && next_token == token_x)) {
                            type_pair_opt = option::some(pair);
                            break
                        };
                        k = k + 1;
                    };
                    if (option::is_none(&type_pair_opt)) {
                        break
                    };
                    vector::push_back(&mut type_pairs, option::extract(&mut type_pair_opt));
                    j = j + 1;
                };
                if (vector::length(&type_pairs) == vector::length(&path_output.token_types) - 1) {
                    let (output, allocations) = estimate_path_output_dynamic(registry, &path_output.token_types, &type_pairs, alloc_amount);
                    if (output > 0) {
                        vector::push_back(&mut current_allocations, PathOutput {
                            token_types: path_output.token_types,
                            amount_in: alloc_amount,
                            pool_allocations: allocations,
                        });
                        current_total_out = current_total_out + output;
                    };
                };
                i = i + 1;
            };

            if (current_total_out > best_total_out) {
                best_total_out = current_total_out;
                best_allocations = current_allocations;
            };
            remaining_amount = if (remaining_amount > step) remaining_amount - step else 0;
            iteration = iteration + 1;
        };

        // Convert to PathAllocation
        i = 0;
        while (i < vector::length(&best_allocations)) {
            let path_output = *vector::borrow(&best_allocations, i);
            let type_pairs = vector::empty<TypePair>();
            let mut j = 0;
            while (j < vector::length(&path_output.token_types) - 1) {
                let current_token = *vector::borrow(&path_output.token_types, j);
                let next_token = *vector::borrow(&path_output.token_types, j + 1);
                let mut type_pair_opt = option::none<TypePair>();
                let mut type_pairs = clmm::get_type_pairs(registry);
                let mut k = 0;
                while (k < vector::length(&type_pairs)) {
                    let pair = *vector::borrow(&type_pairs, k);
                    let token_x = get_type_pair_token_x(&pair);
                    let token_y = get_type_pair_token_y(&pair);
                    if ((current_token == token_x && next_token == token_y) || 
                        (current_token == token_y && next_token == token_x)) {
                        type_pair_opt = option::some(pair);
                        break
                    };
                    k = k + 1;
                };
                if (option::is_none(&type_pair_opt)) {
                    break
                };
                vector::push_back(&mut type_pairs, option::extract(&mut type_pair_opt));
                j = j + 1;
            };
            if (vector::length(&type_pairs) == vector::length(&path_output.token_types) - 1) {
                let (output, _) = estimate_path_output_dynamic(registry, &path_output.token_types, &type_pairs, path_output.amount_in);
                let proportion = if (amount_in > 0) ((path_output.amount_in as u128) * 10000 / (amount_in as u128) as u64) else 0;
                vector::push_back(&mut path_allocations, PathAllocation {
                    token_types: path_output.token_types,
                    pool_allocations: path_output.pool_allocations,
                    amount_in: path_output.amount_in,
                    expected_out: output,
                    proportion,
                });
                total_out = total_out + output;
            };
            i = i + 1;
        };

        SwapRoute {
            paths: path_allocations,
            total_in: amount_in,
            total_out,
        }
    }

    // Generic swap function (single-hop only)
    public entry fun swap<X, Y>(
        router: &mut SwapRouter,
        registry: &mut PoolRegistry,
        coin_in: Coin<X>,
        mut paths: vector<SwapPath>,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EInvalidAmount);
        let token_in = type_name::get<X>();
        let token_out = type_name::get<Y>();
        let route = estimate_multi_path_swap(registry, token_in, token_out, amount_in);
        assert!(route.total_out >= min_amount_out, EInsufficientOutput);
        assert!(!vector::is_empty(&route.paths), ENoPathFound);

        let mut total_out = coin::zero<Y>(ctx);
        let mut i = 0;
        let mut remaining_in = coin_in;
        while (i < vector::length(&route.paths)) {
            let path_alloc = vector::borrow(&route.paths, i);
            let alloc_amount = path_alloc.amount_in;
            if (alloc_amount == 0) {
                i = i + 1;
                continue
            };
            assert!(vector::length(&path_alloc.token_types) == 2, EInvalidPathLength); // Restrict to single-hop
            let pool_alloc = *vector::borrow(&path_alloc.pool_allocations, 0);
            let pool_addr = pool_alloc.pool_addr;
            let expected_out = pool_alloc.expected_out;
            let is_x_to_y = pool_alloc.is_x_to_y;

            // Find the SwapPath that matches the current path
            let mut path_found = false;
            let mut k = 0;
            let mut type_pair = create_type_pair<X, Y>();
            while (k < vector::length(&paths)) {
                let swap_path = vector::borrow(&paths, k);
                if (vector::length(&swap_path.token_types) == 2 &&
                    *vector::borrow(&swap_path.token_types, 0) == *vector::borrow(&path_alloc.token_types, 0) &&
                    *vector::borrow(&swap_path.token_types, 1) == *vector::borrow(&path_alloc.token_types, 1) &&
                    *vector::borrow(&swap_path.pool_addrs, 0) == pool_addr) {
                    path_found = true;
                    type_pair = *vector::borrow(&swap_path.type_pairs, 0);
                    break
                };
                k = k + 1;
            };
            assert!(path_found, EInvalidPath);

            let pools = table::borrow(clmm::get_pools(registry), type_pair);
            let mut pool_found = false;
            k = 0;
            while (k < vector::length(pools)) {
                let pool_info = vector::borrow(pools, k);
                if (clmm::get_pool_addr(pool_info) == pool_addr) {
                    pool_found = true;
                    let current_coin_x = coin::split(&mut remaining_in, alloc_amount, ctx);
                    if (get_type_pair_token_x(&type_pair) == token_in && 
                        get_type_pair_token_y(&type_pair) == token_out && is_x_to_y) {
                        let pool = dof::borrow_mut<address, LiquidityPool<X, Y>>(&mut router.id, pool_addr);
                        let coin_out_y = clmm::swap_x_to_y<X, Y>(pool, current_coin_x, expected_out, clock, ctx);
                        coin::join(&mut total_out, coin_out_y);
                    } else if (get_type_pair_token_x(&type_pair) == token_out && 
                               get_type_pair_token_y(&type_pair) == token_in && !is_x_to_y) {
                        let pool = dof::borrow_mut<address, LiquidityPool<Y, X>>(&mut router.id, pool_addr);
                        let coin_out_x = clmm::swap_y_to_x<Y, X>(pool, current_coin_x, expected_out, clock, ctx);
                        coin::join(&mut total_out, coin_out_x);
                    } else {
                        transfer::public_transfer(current_coin_x, tx_context::sender(ctx));
                    };
                    break
                };
                k = k + 1;
            };
            assert!(pool_found, EPoolNotFound);
            i = i + 1;
        };

        // Transfer any remaining input coins
        if (coin::value(&remaining_in) > 0) {
            transfer::public_transfer(remaining_in, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(remaining_in);
        };

        // Destroy paths as they are not droppable
        while (!vector::is_empty(&paths)) {
            let swap_path = vector::pop_back(&mut paths);
            let SwapPath { id, token_types: _, pool_addrs: _, type_pairs: _ } = swap_path;
            object::delete(id);
        };
        vector::destroy_empty(paths);

        assert!(coin::value(&total_out) >= min_amount_out, EInsufficientOutput);
        transfer::public_transfer(total_out, tx_context::sender(ctx));
    }
}