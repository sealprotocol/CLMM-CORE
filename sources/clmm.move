#[allow(unused_variable, unused_use, duplicate_alias, deprecated_usage, unused_const, unused_function)]
module clmm::clmm {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::type_name::{Self, TypeName};
    use std::vector;
    use std::ascii;
    use clmm::xseal::{Self, StakingPool};

    // Error codes
    const EInsufficientLiquidity: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;
    const EInsufficientBalance: u64 = 3;
    const EInvalidFee: u64 = 4;
    const EInvalidTokenPair: u64 = 5;
    const EInvalidRatio: u64 = 6;
    const ENoLiquidity: u64 = 7;
    const EInvalidTimestamp: u64 = 8;
    const ENotAdmin: u64 = 9;
    const EInvalidTokenOrder: u64 = 10;
    const EInvalidPath: u64 = 11;
    const EPoolNotFound: u64 = 12;
    const ENoValidPools: u64 = 13;
    const EInsufficientOutput: u64 = 14;

    // Admin capability
    public struct AdminCap has key {
        id: UID,
    }

    // Liquidity Pool struct
    public struct LiquidityPool<phantom X, phantom Y> has key, store {
        id: UID,
        reserve_x: Balance<X>,
        reserve_y: Balance<Y>,
        fee_rate: u64, // Basis points (e.g., 25 = 0.25%)
        total_liquidity: u128,
        user_shares: Table<address, u128>,
        fee_balance_x: Balance<X>,
        fee_balance_y: Balance<Y>,
        platform_fee_x: Balance<X>,
        platform_fee_y: Balance<Y>,
        volume_24h: u64,
        fees_24h: u64,
        last_update: u64,
    }

    // Pool Registry
    public struct PoolRegistry has key, store {
        id: UID,
        pools: Table<TypePair, vector<PoolInfo>>,
        type_pairs: vector<TypePair>,
        total_tvl: u64,
        is_distribution_enabled: bool, // Switch for fee distribution
        staking_pool: address, // Address of the StakingPool
        developer_wallet: address, // Developer wallet address
    }

    // Type pair for indexing pools
    public struct TypePair has copy, drop, store {
        token_x: TypeName,
        token_y: TypeName,
    }

    // Pool metadata
    public struct PoolInfo has store, copy, drop {
        token_x: TypeName,
        token_y: TypeName,
        pool_addr: address,
        fee_rate: u64,
    }

    // Constants
    const DEVELOPER_WALLET: address = @0x1234567890abcdef; // Placeholder developer wallet address

    // Getters for PoolRegistry and PoolInfo
    public fun get_pools(registry: &PoolRegistry): &Table<TypePair, vector<PoolInfo>> {
        &registry.pools
    }

    public fun get_type_pairs(registry: &PoolRegistry): vector<TypePair> {
        registry.type_pairs
    }

    public fun get_registry_id(registry: &PoolRegistry): &UID {
        &registry.id
    }

    public fun get_pool_addr(info: &PoolInfo): address {
        info.pool_addr
    }

    public fun get_type_pair_token_x(pair: &TypePair): TypeName {
        pair.token_x
    }

    public fun get_type_pair_token_y(pair: &TypePair): TypeName {
        pair.token_y
    }

    public fun get_pool_info_fee_rate(info: &PoolInfo): u64 {
        info.fee_rate
    }

    // Get all token types in registry
    public fun get_all_token_types(registry: &PoolRegistry): vector<TypeName> {
        let mut token_types = vector::empty<TypeName>();
        let type_pairs = &registry.type_pairs;
        let mut i = 0;
        while (i < vector::length(type_pairs)) {
            let pair = vector::borrow(type_pairs, i);
            let token_x = pair.token_x;
            let token_y = pair.token_y;
            if (!vector::contains(&token_types, &token_x)) {
                vector::push_back(&mut token_types, token_x);
            };
            if (!vector::contains(&token_types, &token_y)) {
                vector::push_back(&mut token_types, token_y);
            };
            i = i + 1;
        };
        token_types
    }

    // Compare two byte vectors lexicographically
    public fun compare_bytes(a: &vector<u8>, b: &vector<u8>): bool {
        let len_a = vector::length(a);
        let len_b = vector::length(b);
        let min_len = if (len_a < len_b) len_a else len_b;
        let mut i = 0;

        while (i < min_len) {
            let byte_a = *vector::borrow(a, i);
            let byte_b = *vector::borrow(b, i);
            if (byte_a < byte_b) return true;
            if (byte_a > byte_b) return false;
            i = i + 1;
        };
        len_a < len_b
    }

    // Create TypePair
    public fun create_type_pair<X, Y>(): TypePair {
        let token_x_name = type_name::get<X>();
        let token_y_name = type_name::get<Y>();
        TypePair { token_x: token_x_name, token_y: token_y_name }
    }

    // Initialize module
    fun init(ctx: &mut TxContext) {
        let registry = PoolRegistry {
            id: object::new(ctx),
            pools: table::new(ctx),
            type_pairs: vector::empty(),
            total_tvl: 0,
            is_distribution_enabled: false,
            staking_pool: @0x0, // Placeholder, to be set later
            developer_wallet: DEVELOPER_WALLET,
        };
        transfer::public_share_object(registry);

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // Set staking pool address
    public entry fun set_staking_pool(
        _cap: &AdminCap,
        registry: &mut PoolRegistry,
        staking_pool: address,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == registry.developer_wallet, ENotAdmin);
        registry.staking_pool = staking_pool;
    }

    // Enable fee distribution (called after TGE)
    public entry fun enable_distribution(
        _cap: &AdminCap,
        registry: &mut PoolRegistry,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == registry.developer_wallet, ENotAdmin);
        assert!(registry.staking_pool != @0x0, EInvalidAmount); // Ensure staking pool is set
        registry.is_distribution_enabled = true;
    }

    // Create a new liquidity pool with sorted token pair
    public entry fun create_pool<X, Y>(
        registry: &mut PoolRegistry,
        fee_rate: u64,
        ctx: &mut TxContext
    ) {
        assert!(
            fee_rate == 0 || fee_rate == 1 || fee_rate == 5 || fee_rate == 20 || fee_rate == 25 || fee_rate == 100 || fee_rate == 200,
            EInvalidFee
        );
        assert!(type_name::get<X>() != type_name::get<Y>(), EInvalidTokenPair);

        let token_x_name = type_name::get<X>();
        let token_y_name = type_name::get<Y>();
        let token_x_str = type_name::into_string(token_x_name);
        let token_y_str = type_name::into_string(token_y_name);
        assert!(compare_bytes(&ascii::into_bytes(token_x_str), &ascii::into_bytes(token_y_str)), EInvalidTokenOrder);

        let type_pair = create_type_pair<X, Y>();
        if (!table::contains(&registry.pools, type_pair)) {
            table::add(&mut registry.pools, type_pair, vector::empty());
            vector::push_back(&mut registry.type_pairs, type_pair);
        };
        let pools = table::borrow_mut(&mut registry.pools, type_pair);
        let mut i = 0;
        while (i < vector::length(pools)) {
            let pool_info = vector::borrow(pools, i);
            assert!(get_pool_info_fee_rate(pool_info) != fee_rate, EPoolAlreadyExists);
            i = i + 1;
        };

        let pool = LiquidityPool<X, Y> {
            id: object::new(ctx),
            reserve_x: balance::zero(),
            reserve_y: balance::zero(),
            fee_rate,
            total_liquidity: 0,
            user_shares: table::new(ctx),
            fee_balance_x: balance::zero(),
            fee_balance_y: balance::zero(),
            platform_fee_x: balance::zero(),
            platform_fee_y: balance::zero(),
            volume_24h: 0,
            fees_24h: 0,
            last_update: 0,
        };
        let pool_addr = object::uid_to_address(&pool.id);

        let pool_info = PoolInfo {
            token_x: token_x_name,
            token_y: token_y_name,
            pool_addr,
            fee_rate,
        };
        vector::push_back(pools, pool_info);

        transfer::public_share_object(pool);
    }

    // Add initial liquidity
    public entry fun add_liquidity_initial<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        registry: &mut PoolRegistry,
        ctx: &mut TxContext
    ) {
        let amount_x = coin::value(&coin_x);
        let amount_y = coin::value(&coin_y);
        assert!(amount_x > 0 && amount_y > 0, EInvalidAmount);
        assert!(pool.total_liquidity == 0, EInvalidRatio);

        let product = (amount_x as u128) * (amount_y as u128);
        let liquidity = sqrt_u128(product);
        assert!(liquidity > 0, EInsufficientLiquidity);

        balance::join(&mut pool.reserve_x, coin::into_balance(coin_x));
        balance::join(&mut pool.reserve_y, coin::into_balance(coin_y));
        pool.total_liquidity = pool.total_liquidity + liquidity;

        let sender = tx_context::sender(ctx);
        table::add(&mut pool.user_shares, sender, liquidity);

        registry.total_tvl = registry.total_tvl + amount_x;
    }

    // Add additional liquidity
    public entry fun add_liquidity_additional<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        registry: &mut PoolRegistry,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let amount_x = coin::value(&coin_x);
        let amount_y = coin::value(&coin_y);
        assert!(amount_x > 0 && amount_y > 0, EInvalidAmount);

        let reserve_x = balance::value(&pool.reserve_x);
        let reserve_y = balance::value(&pool.reserve_y);
        assert!(reserve_x > 0 && reserve_y > 0, EInsufficientBalance);

        assert!((amount_x as u128) * (reserve_y as u128) == (amount_y as u128) * (reserve_x as u128), EInvalidRatio);
        let liquidity = ((amount_x as u128) * pool.total_liquidity) / (reserve_x as u128);
        assert!(liquidity > 0, EInsufficientLiquidity);

        balance::join(&mut pool.reserve_x, coin::into_balance(coin_x));
        balance::join(&mut pool.reserve_y, coin::into_balance(coin_y));
        pool.total_liquidity = pool.total_liquidity + liquidity;

        let current_liquidity = if (table::contains(&pool.user_shares, sender)) {
            *table::borrow(&pool.user_shares, sender)
        } else {
            0
        };
        table::add(&mut pool.user_shares, sender, current_liquidity + liquidity);

        registry.total_tvl = registry.total_tvl + amount_x;
    }

    // Remove liquidity
    public entry fun remove_liquidity<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        amount: u128,
        registry: &mut PoolRegistry,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&pool.user_shares, sender), ENoLiquidity);
        let user_liquidity = *table::borrow(&pool.user_shares, sender);
        assert!(user_liquidity >= amount, EInvalidAmount);

        let reserve_x = balance::value(&pool.reserve_x);
        let reserve_y = balance::value(&pool.reserve_y);
        let amount_x = ((amount as u256) * (reserve_x as u256) / (pool.total_liquidity as u256) as u64);
        let amount_y = ((amount as u256) * (reserve_y as u256) / (pool.total_liquidity as u256) as u64);

        assert!(amount_x > 0 && amount_y > 0, EInsufficientLiquidity);

        pool.total_liquidity = pool.total_liquidity - amount;

        if (user_liquidity == amount) {
            table::remove(&mut pool.user_shares, sender);
        } else {
            table::add(&mut pool.user_shares, sender, user_liquidity - amount);
        };

        let coin_x = coin::from_balance(balance::split(&mut pool.reserve_x, amount_x), ctx);
        let coin_y = coin::from_balance(balance::split(&mut pool.reserve_y, amount_y), ctx);
        transfer::public_transfer(coin_x, sender);
        transfer::public_transfer(coin_y, sender);

        registry.total_tvl = registry.total_tvl - amount_x;
    }

    // Claim accumulated fees for LPs
    public entry fun claim_fees<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&pool.user_shares, sender), ENoLiquidity);
        let user_liquidity = *table::borrow(&pool.user_shares, sender);

        let total_fees_x = balance::value(&pool.fee_balance_x);
        let total_fees_y = balance::value(&pool.fee_balance_y);
        let user_fee_x = if (pool.total_liquidity > 0) {
            ((user_liquidity as u256) * (total_fees_x as u256) / (pool.total_liquidity as u256)) as u64
        } else {
            0
        };
        let user_fee_y = if (pool.total_liquidity > 0) {
            ((user_liquidity as u256) * (total_fees_y as u256) / (pool.total_liquidity as u256)) as u64
        } else {
            0
        };

        if (user_fee_x > 0) {
            let coin_x = coin::from_balance(balance::split(&mut pool.fee_balance_x, user_fee_x), ctx);
            transfer::public_transfer(coin_x, sender);
        };
        if (user_fee_y > 0) {
            let coin_y = coin::from_balance(balance::split(&mut pool.fee_balance_y, user_fee_y), ctx);
            transfer::public_transfer(coin_y, sender);
        }
    }

    // Claim accumulated platform fees
    public entry fun claim_platform_fees<X, Y>(
        _cap: &AdminCap,
        pool: &mut LiquidityPool<X, Y>,
        registry: &PoolRegistry,
        staking_pool: &mut StakingPool,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == registry.developer_wallet, ENotAdmin);

        let total_platform_fees_x = balance::value(&pool.platform_fee_x);
        let total_platform_fees_y = balance::value(&pool.platform_fee_y);

        if (registry.is_distribution_enabled && registry.staking_pool != @0x0) {
            // Distribute to staking pool
            if (total_platform_fees_x > 0) {
                let coin_x = coin::from_balance(balance::split(&mut pool.platform_fee_x, total_platform_fees_x), ctx);
                xseal::distribute_fees(staking_pool, coin_x, ctx);
            };
            if (total_platform_fees_y > 0) {
                let coin_y = coin::from_balance(balance::split(&mut pool.platform_fee_y, total_platform_fees_y), ctx);
                xseal::distribute_fees(staking_pool, coin_y, ctx);
            };
        } else {
            // Transfer to developer wallet
            if (total_platform_fees_x > 0) {
                let coin_x = coin::from_balance(balance::split(&mut pool.platform_fee_x, total_platform_fees_x), ctx);
                transfer::public_transfer(coin_x, registry.developer_wallet);
            };
            if (total_platform_fees_y > 0) {
                let coin_y = coin::from_balance(balance::split(&mut pool.platform_fee_y, total_platform_fees_y), ctx);
                transfer::public_transfer(coin_y, registry.developer_wallet);
            };
        }
    }

    // Swap X to Y (single pool)
    public fun swap_x_to_y<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_in: Coin<X>,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Y> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EInvalidAmount);

        let reserve_x = balance::value(&pool.reserve_x);
        let reserve_y = balance::value(&pool.reserve_y);
        assert!(reserve_x > 0 && reserve_y > 0, EInsufficientLiquidity);

        let amount_in_with_fee = (amount_in as u128) * ((10000 - pool.fee_rate) as u128);
        let amount_out = (amount_in_with_fee * (reserve_y as u128)) / (((reserve_x as u128) * (10000 as u128)) + amount_in_with_fee);
        assert!(amount_out >= (min_amount_out as u128), EInsufficientLiquidity);
        assert!(amount_out <= (reserve_y as u128), EInsufficientBalance);

        let fee_amount = (amount_in as u128) * (pool.fee_rate as u128) / (10000 as u128);
        let platform_fee = (fee_amount * 20) / 100;
        let lp_fee = fee_amount - platform_fee;

        let mut balance_in = coin::into_balance(coin_in);
        let mut fee_balance = balance::split(&mut balance_in, (fee_amount as u64));
        let platform_fee_balance = balance::split(&mut fee_balance, (platform_fee as u64));
        let lp_fee_balance = fee_balance;

        balance::join(&mut pool.platform_fee_x, platform_fee_balance);
        balance::join(&mut pool.fee_balance_x, lp_fee_balance);
        balance::join(&mut pool.reserve_x, balance_in);
        let coin_out = coin::from_balance(balance::split(&mut pool.reserve_y, (amount_out as u64)), ctx);

        update_metrics(pool, amount_in, (fee_amount as u64), clock);
        coin_out
    }

    // Swap Y to X (single pool)
    public fun swap_y_to_x<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_in: Coin<Y>,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<X> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EInvalidAmount);

        let reserve_x = balance::value(&pool.reserve_x);
        let reserve_y = balance::value(&pool.reserve_y);
        assert!(reserve_x > 0 && reserve_y > 0, EInsufficientLiquidity);

        let amount_in_with_fee = (amount_in as u128) * ((10000 - pool.fee_rate) as u128);
        let amount_out = (amount_in_with_fee * (reserve_x as u128)) / (((reserve_y as u128) * (10000 as u128)) + amount_in_with_fee);
        assert!(amount_out >= (min_amount_out as u128), EInsufficientLiquidity);
        assert!(amount_out <= (reserve_x as u128), EInsufficientBalance);

        let fee_amount = (amount_in as u128) * (pool.fee_rate as u128) / (10000 as u128);
        let platform_fee = (fee_amount * 20) / 100;
        let lp_fee = fee_amount - platform_fee;

        let mut balance_in = coin::into_balance(coin_in);
        let mut fee_balance = balance::split(&mut balance_in, (fee_amount as u64));
        let platform_fee_balance = balance::split(&mut fee_balance, (platform_fee as u64));
        let lp_fee_balance = fee_balance;

        balance::join(&mut pool.platform_fee_y, platform_fee_balance);
        balance::join(&mut pool.fee_balance_y, lp_fee_balance);
        balance::join(&mut pool.reserve_y, balance_in);
        let coin_out = coin::from_balance(balance::split(&mut pool.reserve_x, (amount_out as u64)), ctx);

        update_metrics(pool, amount_in, (fee_amount as u64), clock);
        coin_out
    }

    // Update 24-hour metrics
    fun update_metrics<X, Y>(pool: &mut LiquidityPool<X, Y>, volume: u64, fee: u64, clock: &Clock) {
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= pool.last_update, EInvalidTimestamp);
        let one_day_ms = 24 * 60 * 60 * 1000;

        if (current_time >= pool.last_update + one_day_ms) {
            pool.volume_24h = volume;
            pool.fees_24h = fee;
            pool.last_update = current_time;
        } else {
            pool.volume_24h = pool.volume_24h + volume;
            pool.fees_24h = pool.fees_24h + fee;
        };
    }

    // Get pool reserves and fees
    public fun get_pool_info<X, Y>(pool: &LiquidityPool<X, Y>): (u64, u64, u64, u64, u64, address) {
        (
            balance::value(&pool.reserve_x),
            balance::value(&pool.reserve_y),
            pool.fee_rate,
            pool.volume_24h,
            pool.fees_24h,
            object::uid_to_address(&pool.id)
        )
    }

    // Get user's liquidity and pending fees
    public fun get_user_info<X, Y>(pool: &LiquidityPool<X, Y>, user: address): (u128, u64, u64) {
        let user_liquidity = if (table::contains(&pool.user_shares, user)) {
            *table::borrow(&pool.user_shares, user)
        } else {
            0
        };
        let user_fee_x = if (pool.total_liquidity > 0) {
            ((user_liquidity as u256) * (balance::value(&pool.fee_balance_x) as u256) / (pool.total_liquidity as u256)) as u64
        } else {
            0
        };
        let user_fee_y = if (pool.total_liquidity > 0) {
            ((user_liquidity as u256) * (balance::value(&pool.fee_balance_y) as u256) / (pool.total_liquidity as u256)) as u64
        } else {
            0
        };
        (user_liquidity, user_fee_x, user_fee_y)
    }

    // Estimate APR
    public fun estimate_apr<X, Y>(pool: &LiquidityPool<X, Y>): u64 {
        let fees_24h = pool.fees_24h;
        let reserve_x = balance::value(&pool.reserve_x);
        if (reserve_x == 0) return 0;
        (((fees_24h as u128) * 36500) / (reserve_x as u128)) as u64
    }

    // Get TVL
    public fun get_tvl(registry: &PoolRegistry): u64 {
        registry.total_tvl
    }

    // Get square root
    fun sqrt_u128(y: u128): u128 {
        if (y < 4) {
            if (y == 0) return 0;
            return 1;
        };
        let mut z = y / 2;
        let mut x = y;
        while (z < x) {
            x = z;
            z = (y / z + z) / 2;
        };
        x
    }
}