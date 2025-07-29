module clmm::clmm {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::type_name::{Self, TypeName};
    use sui::event;

    // Error codes
    const EInsufficientLiquidity: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;
    const EInsufficientBalance: u64 = 3;
    const EInvalidFee: u64 = 4;
    const EInvalidTokenPair: u64 = 5;
    const EInvalidTimestamp: u64 = 8;
    const EInvalidTickRange: u64 = 10;
    const EInvalidTick: u64 = 11;
    const EPositionNotFound: u64 = 12;
    const EPriceOutOfRange: u64 = 13;

    // Constants
    const MAX_TICK: u32 = 2_147_483_647;
    const MIN_TICK: u32 = 0;
    const SQRT_PRICE_PRECISION: u128 = 1_000_000_000_000_000_000; // Q64.64
    const FEE_DENOMINATOR: u64 = 1_000_000;

    // Admin capability
    public struct AdminCap has key, store {
        id: sui::object::UID,
    }

    // Position NFT
    public struct Position has key, store {
        id: sui::object::UID,
        pool_id: address,
        tick_lower: u32,
        tick_upper: u32,
        liquidity: u128,
        fee_owed_x: u64,
        fee_owed_y: u64,
    }

    // Tick data
    public struct Tick has store {
        liquidity_gross: u128,
        liquidity_net: u128,
        fee_growth_outside_x: u128,
        fee_growth_outside_y: u128,
    }

    // Liquidity Pool
    public struct LiquidityPool<phantom X, phantom Y> has key, store {
        id: sui::object::UID,
        reserve_x: Balance<X>,
        reserve_y: Balance<Y>,
        fee_rate: u64,
        tick_spacing: u32,
        current_tick: u32,
        current_sqrt_price: u128,
        liquidity: u128,
        ticks: Table<u32, Tick>,
        positions: Table<address, vector<Position>>,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128,
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
        id: sui::object::UID,
        pools: vector<PoolInfo>,
        total_tvl: u64,
    }

    // Pool metadata
    public struct PoolInfo has store, copy, drop {
        token_x: TypeName,
        token_y: TypeName,
        pool_addr: address,
        fee_rate: u64,
        tick_spacing: u32,
    }

    // Events
    public struct PoolCreated has copy, drop {
        pool_id: address,
        token_x: TypeName,
        token_y: TypeName,
        fee_rate: u64,
        tick_spacing: u32,
    }

    public struct LiquidityAdded has copy, drop {
        pool_id: address,
        position_id: address,
        tick_lower: u32,
        tick_upper: u32,
        liquidity: u128,
        amount_x: u64,
        amount_y: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: address,
        position_id: address,
        tick_lower: u32,
        tick_upper: u32,
        liquidity: u128,
        amount_x: u64,
        amount_y: u64,
    }

    public struct SwapEvent has copy, drop {
        pool_id: address,
        amount_in: u64,
        amount_out: u64,
        zero_for_one: bool,
        fee_amount: u64,
    }

    // Initialize module
    fun init(ctx: &mut sui::tx_context::TxContext) {
        let registry = PoolRegistry {
            id: sui::object::new(ctx),
            pools: vector::empty(),
            total_tvl: 0,
        };
        sui::transfer::public_share_object(registry);

        let admin_cap = AdminCap {
            id: sui::object::new(ctx),
        };
        sui::transfer::transfer(admin_cap, sui::tx_context::sender(ctx));
    }

    // Create a new CLMM pool
    public entry fun create_pool<X, Y>(
        registry: &mut PoolRegistry,
        fee_rate: u64,
        tick_spacing: u32,
        initial_sqrt_price: u128,
        ctx: &mut sui::tx_context::TxContext
    ) {
        assert!(fee_rate == 500 || fee_rate == 3000 || fee_rate == 10000, EInvalidFee);
        assert!(tick_spacing > 0, EInvalidTick);
        assert!(type_name::get<X>() != type_name::get<Y>(), EInvalidTokenPair);
        assert!(initial_sqrt_price > 0, EPriceOutOfRange);

        let mut i = 0;
        while (i < vector::length(&registry.pools)) {
            let pool_info = vector::borrow(&registry.pools, i);
            assert!(
                !(pool_info.token_x == type_name::get<X>() && pool_info.token_y == type_name::get<Y>() && pool_info.fee_rate == fee_rate),
                EPoolAlreadyExists
            );
            i = i + 1;
        };

        let pool = LiquidityPool<X, Y> {
            id: sui::object::new(ctx),
            reserve_x: balance::zero<X>(),
            reserve_y: balance::zero<Y>(),
            fee_rate,
            tick_spacing,
            current_tick: MIN_TICK,
            current_sqrt_price: initial_sqrt_price,
            liquidity: 0,
            ticks: table::new(ctx),
            positions: table::new(ctx),
            fee_growth_global_x: 0,
            fee_growth_global_y: 0,
            fee_balance_x: balance::zero<X>(),
            fee_balance_y: balance::zero<Y>(),
            platform_fee_x: balance::zero<X>(),
            platform_fee_y: balance::zero<Y>(),
            volume_24h: 0,
            fees_24h: 0,
            last_update: 0,
        };
        let pool_addr = sui::object::id_address(&pool);

        let pool_info = PoolInfo {
            token_x: type_name::get<X>(),
            token_y: type_name::get<Y>(),
            pool_addr,
            fee_rate,
            tick_spacing,
        };
        vector::push_back(&mut registry.pools, pool_info);

        event::emit(PoolCreated {
            pool_id: pool_addr,
            token_x: type_name::get<X>(),
            token_y: type_name::get<Y>(),
            fee_rate,
            tick_spacing,
        });

        sui::transfer::public_share_object(pool);
    }

    // Add liquidity
    public entry fun add_liquidity<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        tick_lower: u32,
        tick_upper: u32,
        liquidity: u128,
        registry: &mut PoolRegistry,
        ctx: &mut sui::tx_context::TxContext
    ) {
        assert!(tick_lower < tick_upper, EInvalidTickRange);
        assert!(tick_lower >= MIN_TICK && tick_upper <= MAX_TICK, EInvalidTick);
        assert!(tick_lower % pool.tick_spacing == 0 && tick_upper % pool.tick_spacing == 0, EInvalidTick);
        assert!(liquidity > 0, EInvalidAmount);

        let (amount_x, amount_y) = calculate_amounts(pool, tick_lower, tick_upper, liquidity);
        assert!(coin::value(&coin_x) >= amount_x && coin::value(&coin_y) >= amount_y, EInsufficientBalance);

        let sender = sui::tx_context::sender(ctx);
        let position = Position {
            id: sui::object::new(ctx),
            pool_id: sui::object::id_address(pool),
            tick_lower,
            tick_upper,
            liquidity,
            fee_owed_x: 0,
            fee_owed_y: 0,
        };

        update_tick(pool, tick_lower, liquidity, true);
        update_tick(pool, tick_upper, liquidity, false);

        if (pool.current_tick >= tick_lower && pool.current_tick < tick_upper) {
            pool.liquidity = pool.liquidity + liquidity;
        };

        balance::join(&mut pool.reserve_x, coin::into_balance(coin_x));
        balance::join(&mut pool.reserve_y, coin::into_balance(coin_y));

        let user_positions = if (table::contains(&pool.positions, sender)) {
            table::borrow_mut(&mut pool.positions, sender)
        } else {
            table::add(&mut pool.positions, sender, vector::empty());
            table::borrow_mut(&mut pool.positions, sender)
        };
        vector::push_back(user_positions, position);

        let position_for_transfer = Position {
            id: sui::object::new(ctx),
            pool_id: sui::object::id_address(pool),
            tick_lower,
            tick_upper,
            liquidity,
            fee_owed_x: 0,
            fee_owed_y: 0,
        };

        registry.total_tvl = registry.total_tvl + amount_x;

        event::emit(LiquidityAdded {
            pool_id: sui::object::id_address(pool),
            position_id: sui::object::id_address(&position_for_transfer),
            tick_lower,
            tick_upper,
            liquidity,
            amount_x,
            amount_y,
        });

        sui::transfer::public_transfer(position_for_transfer, sender);
    }

    // Remove liquidity
public entry fun remove_liquidity<X, Y>(
    pool: &mut LiquidityPool<X, Y>,
    position: Position,
    liquidity: u128,
    registry: &mut PoolRegistry,
    ctx: &mut sui::tx_context::TxContext
) {
    let sender = sui::tx_context::sender(ctx);
    assert!(position.pool_id == sui::object::id_address(pool), EPositionNotFound);
    assert!(position.liquidity >= liquidity, EInsufficientLiquidity);

    let mut position = position;
    update_position_fees(pool, &mut position);

    let (amount_x, amount_y) = calculate_amounts(pool, position.tick_lower, position.tick_upper, liquidity);

    update_tick(pool, position.tick_lower, liquidity, false);
    update_tick(pool, position.tick_upper, liquidity, true);

    if (pool.current_tick >= position.tick_lower && pool.current_tick < position.tick_upper) {
        pool.liquidity = pool.liquidity - liquidity;
    };

    position.liquidity = position.liquidity - liquidity;

    let coin_x = coin::from_balance(balance::split(&mut pool.reserve_x, amount_x), ctx);
    let coin_y = coin::from_balance(balance::split(&mut pool.reserve_y, amount_y), ctx);
    sui::transfer::public_transfer(coin_x, sender);
    sui::transfer::public_transfer(coin_y, sender);

    registry.total_tvl = registry.total_tvl - amount_x;

    let position_id = sui::object::id_address(&position);
    event::emit(LiquidityRemoved {
        pool_id: sui::object::id_address(pool),
        position_id,
        tick_lower: position.tick_lower,
        tick_upper: position.tick_upper,
        liquidity,
        amount_x,
        amount_y,
    });

    let user_positions = table::borrow_mut(&mut pool.positions, sender);
    if (position.liquidity == 0) {
        let Position { id, pool_id: _, tick_lower: _, tick_upper: _, liquidity: _, fee_owed_x, fee_owed_y } = position;
        sui::object::delete(id);
        if (fee_owed_x > 0) {
            let coin_x = coin::from_balance(balance::split(&mut pool.fee_balance_x, fee_owed_x), ctx);
            sui::transfer::public_transfer(coin_x, sender);
        };
        if (fee_owed_y > 0) {
            let coin_y = coin::from_balance(balance::split(&mut pool.fee_balance_y, fee_owed_y), ctx);
            sui::transfer::public_transfer(coin_y, sender);
        };
        // Remove position from the table
        let mut i = 0;
        while (i < vector::length(user_positions)) {
            let p = vector::borrow(user_positions, i);
            if (sui::object::id_address(p) == position_id) {
                let removed_position = vector::swap_remove(user_positions, i);
                let Position { id, pool_id: _, tick_lower: _, tick_upper: _, liquidity: _, fee_owed_x: _, fee_owed_y: _ } = removed_position;
                sui::object::delete(id);
                break
            };
            i = i + 1;
        };
    } else {
        // Update position in the table by removing and re-adding
        let mut i = 0;
        let mut found = false;
        while (i < vector::length(user_positions)) {
            let p = vector::borrow(user_positions, i);
            if (sui::object::id_address(p) == position_id) {
                let removed_position = vector::swap_remove(user_positions, i);
                let Position { id, pool_id: _, tick_lower: _, tick_upper: _, liquidity: _, fee_owed_x: _, fee_owed_y: _ } = removed_position;
                sui::object::delete(id);
                // Create a new Position for storage
                let new_position = Position {
                    id: sui::object::new(ctx),
                    pool_id: position.pool_id,
                    tick_lower: position.tick_lower,
                    tick_upper: position.tick_upper,
                    liquidity: position.liquidity,
                    fee_owed_x: position.fee_owed_x,
                    fee_owed_y: position.fee_owed_y,
                };
                vector::push_back(user_positions, new_position);
                found = true;
                break
            };
            i = i + 1;
        };
        // If no matching position was found, transfer a new Position back to the sender
        if (!found) {
            let new_position = Position {
                id: sui::object::new(ctx),
                pool_id: position.pool_id,
                tick_lower: position.tick_lower,
                tick_upper: position.tick_upper,
                liquidity: position.liquidity,
                fee_owed_x: position.fee_owed_x,
                fee_owed_y: position.fee_owed_y,
            };
            sui::transfer::public_transfer(new_position, sender);
        };
        // Delete the original position to consume it
        let Position { id, pool_id: _, tick_lower: _, tick_upper: _, liquidity: _, fee_owed_x: _, fee_owed_y: _ } = position;
        sui::object::delete(id);
    };
}
   

    // Swap X to Y
    public entry fun swap<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_in: Coin<X>,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EInvalidAmount);

        let (amount_out, fee_amount) = swap_internal(pool, amount_in, true);
        assert!(amount_out >= min_amount_out, EInsufficientLiquidity);

        let mut balance_in = coin::into_balance(coin_in);
        let platform_fee = (fee_amount * 20) / 100;
        let _lp_fee = fee_amount - platform_fee;

        balance::join(&mut pool.reserve_x, balance::split(&mut balance_in, amount_in - fee_amount));
        balance::join(&mut pool.platform_fee_x, balance::split(&mut balance_in, platform_fee));
        balance::join(&mut pool.fee_balance_x, balance_in);

        let coin_out = coin::from_balance(balance::split(&mut pool.reserve_y, amount_out), ctx);
        sui::transfer::public_transfer(coin_out, sui::tx_context::sender(ctx));

        event::emit(SwapEvent {
            pool_id: sui::object::id_address(pool),
            amount_in,
            amount_out,
            zero_for_one: true,
            fee_amount,
        });

        update_metrics(pool, amount_in, fee_amount, clock);
    }

    // Swap Y to X
    public entry fun swap_reverse<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_in: Coin<Y>,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, EInvalidAmount);

        let (amount_out, fee_amount) = swap_internal(pool, amount_in, false);
        assert!(amount_out >= min_amount_out, EInsufficientLiquidity);

        let mut balance_in = coin::into_balance(coin_in);
        let platform_fee = (fee_amount * 20) / 100;
        let _lp_fee = fee_amount - platform_fee;

        balance::join(&mut pool.reserve_y, balance::split(&mut balance_in, amount_in - fee_amount));
        balance::join(&mut pool.platform_fee_y, balance::split(&mut balance_in, platform_fee));
        balance::join(&mut pool.fee_balance_y, balance_in);

        let coin_out = coin::from_balance(balance::split(&mut pool.reserve_x, amount_out), ctx);
        sui::transfer::public_transfer(coin_out, sui::tx_context::sender(ctx));

        event::emit(SwapEvent {
            pool_id: sui::object::id_address(pool),
            amount_in,
            amount_out,
            zero_for_one: false,
            fee_amount,
        });

        update_metrics(pool, amount_in, fee_amount, clock);
    }

    // Internal swap logic
    fun swap_internal<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        amount_in: u64,
        zero_for_one: bool
    ): (u64, u64) {
        let fee_amount = (amount_in * pool.fee_rate) / FEE_DENOMINATOR;
        let mut amount_in_net = amount_in - fee_amount;
        let mut amount_out = 0;
        let mut next_tick = pool.current_tick;

        while (amount_in_net > 0) {
            if (zero_for_one) {
                if (next_tick == MIN_TICK) break;
                next_tick = next_initialized_tick(pool, next_tick, true);
                let sqrt_price_next = tick_to_sqrt_price(next_tick);
                let (delta_out, delta_in) = calculate_swap_step(
                    pool.current_sqrt_price,
                    sqrt_price_next,
                    pool.liquidity,
                    amount_in_net,
                    zero_for_one
                );
                amount_out = amount_out + delta_out;
                pool.current_sqrt_price = sqrt_price_next;
                pool.current_tick = next_tick;
                amount_in_net = amount_in_net - delta_in;
                if (delta_in == 0) break;
            } else {
                if (next_tick == MAX_TICK) break;
                next_tick = next_initialized_tick(pool, next_tick, false);
                let sqrt_price_next = tick_to_sqrt_price(next_tick);
                let (delta_out, delta_in) = calculate_swap_step(
                    pool.current_sqrt_price,
                    sqrt_price_next,
                    pool.liquidity,
                    amount_in_net,
                    zero_for_one
                );
                amount_out = amount_out + delta_out;
                pool.current_sqrt_price = sqrt_price_next;
                pool.current_tick = next_tick;
                amount_in_net = amount_in_net - delta_in;
                if (delta_in == 0) break;
            };
        };

        update_fee_growth(pool, fee_amount, zero_for_one);
        (amount_out, fee_amount)
    }

    // Calculate amounts for liquidity
    fun calculate_amounts<X, Y>(
        pool: &LiquidityPool<X, Y>,
        tick_lower: u32,
        tick_upper: u32,
        liquidity: u128
    ): (u64, u64) {
        let sqrt_price_lower = tick_to_sqrt_price(tick_lower);
        let sqrt_price_upper = tick_to_sqrt_price(tick_upper);
        let current_sqrt_price = pool.current_sqrt_price;

        let mut amount_x = 0;
        let mut amount_y = 0;

        if (current_sqrt_price >= sqrt_price_lower && current_sqrt_price < sqrt_price_upper) {
            amount_x = ((liquidity * (sqrt_price_upper - current_sqrt_price)) / (current_sqrt_price * sqrt_price_upper / SQRT_PRICE_PRECISION)) as u64;
            amount_y = ((liquidity * (current_sqrt_price - sqrt_price_lower)) / SQRT_PRICE_PRECISION) as u64;
        } else if (current_sqrt_price < sqrt_price_lower) {
            amount_x = ((liquidity * (sqrt_price_upper - sqrt_price_lower)) / (sqrt_price_lower * sqrt_price_upper / SQRT_PRICE_PRECISION)) as u64;
        } else {
            amount_y = ((liquidity * (sqrt_price_upper - sqrt_price_lower)) / SQRT_PRICE_PRECISION) as u64;
        };

        (amount_x, amount_y)
    }

    // Update tick data
    fun update_tick<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        tick: u32,
        liquidity_delta: u128,
        lower: bool
    ) {
        let tick_data = if (table::contains(&pool.ticks, tick)) {
            table::borrow_mut(&mut pool.ticks, tick)
        } else {
            table::add(&mut pool.ticks, tick, Tick {
                liquidity_gross: 0,
                liquidity_net: 0,
                fee_growth_outside_x: 0,
                fee_growth_outside_y: 0,
            });
            table::borrow_mut(&mut pool.ticks, tick)
        };

        tick_data.liquidity_gross = tick_data.liquidity_gross + liquidity_delta;
        if (lower) {
            tick_data.liquidity_net = tick_data.liquidity_net + liquidity_delta;
        } else {
            tick_data.liquidity_net = tick_data.liquidity_net - liquidity_delta;
        };
    }

    // Update fee growth
    fun update_fee_growth<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        fee_amount: u64,
        zero_for_one: bool
    ) {
        if (pool.liquidity > 0) {
            let fee_growth = ((fee_amount as u128) * SQRT_PRICE_PRECISION) / pool.liquidity;
            if (zero_for_one) {
                pool.fee_growth_global_x = pool.fee_growth_global_x + fee_growth;
            } else {
                pool.fee_growth_global_y = pool.fee_growth_global_y + fee_growth;
            };
        };
    }

    // Update position fees
    fun update_position_fees<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        position: &mut Position
    ) {
        let tick_lower = position.tick_lower;
        let tick_upper = position.tick_upper;
        let tick_data_lower = table::borrow(&pool.ticks, tick_lower);
        let _tick_data_upper = table::borrow(&pool.ticks, tick_upper);

        let fee_growth_inside_x = if (pool.current_tick >= tick_lower && pool.current_tick < tick_upper) {
            pool.fee_growth_global_x - tick_data_lower.fee_growth_outside_x
        } else {
            tick_data_lower.fee_growth_outside_x
        };
        let fee_growth_inside_y = if (pool.current_tick >= tick_lower && pool.current_tick < tick_upper) {
            pool.fee_growth_global_y - tick_data_lower.fee_growth_outside_y
        } else {
            tick_data_lower.fee_growth_outside_y
        };

        let fee_x = ((position.liquidity * fee_growth_inside_x) / SQRT_PRICE_PRECISION) as u64;
        let fee_y = ((position.liquidity * fee_growth_inside_y) / SQRT_PRICE_PRECISION) as u64;
        position.fee_owed_x = position.fee_owed_x + fee_x;
        position.fee_owed_y = position.fee_owed_y + fee_y;
    }

    // Get next initialized tick
    fun next_initialized_tick<X, Y>(
        pool: &LiquidityPool<X, Y>,
        current_tick: u32,
        zero_for_one: bool
    ): u32 {
        let mut next_tick = if (zero_for_one) {
            current_tick - pool.tick_spacing
        } else {
            current_tick + pool.tick_spacing
        };

        while (next_tick >= MIN_TICK && next_tick <= MAX_TICK) {
            if (table::contains(&pool.ticks, next_tick)) {
                let tick_data = table::borrow(&pool.ticks, next_tick);
                if (tick_data.liquidity_gross > 0) {
                    return next_tick
                };
            };
            next_tick = if (zero_for_one) {
                next_tick - pool.tick_spacing
            } else {
                next_tick + pool.tick_spacing
            };
        };
        if (zero_for_one) MIN_TICK else MAX_TICK
    }

    // Custom power function for u128
    fun pow_u128(base: u128, exponent: u128): u128 {
        if (exponent == 0) return 1;
        let mut result = 1;
        let mut b = base;
        let mut e = exponent;
        while (e > 0) {
            if (e % 2 == 1) {
                result = result * b;
            };
            b = b * b;
            e = e / 2;
        };
        result
    }

    // Convert tick to sqrt price
    fun tick_to_sqrt_price(tick: u32): u128 {
        let tick_abs = (tick as u128);
        let base = 10001; // Approximation of 1.0001
        let exponent = tick_abs / 2;
        let sqrt_price = (pow_u128(base, exponent) * SQRT_PRICE_PRECISION) / pow_u128(10, 4);
        sqrt_price
    }

    // Calculate swap step
    fun calculate_swap_step(
        sqrt_price_current: u128,
        sqrt_price_next: u128,
        liquidity: u128,
        amount_in: u64,
        zero_for_one: bool
    ): (u64, u64) {
        let mut _delta_out: u64 = 0;
        let mut _delta_in: u64 = 0;

        if (zero_for_one) {
            _delta_out = ((liquidity * (sqrt_price_current - sqrt_price_next)) / (sqrt_price_current * sqrt_price_next / SQRT_PRICE_PRECISION)) as u64;
            _delta_in = ((liquidity * (sqrt_price_current - sqrt_price_next)) / SQRT_PRICE_PRECISION) as u64;
        } else {
            _delta_out = ((liquidity * (sqrt_price_next - sqrt_price_current)) / SQRT_PRICE_PRECISION) as u64;
            _delta_in = ((liquidity * (sqrt_price_next - sqrt_price_current)) / (sqrt_price_current * sqrt_price_next / SQRT_PRICE_PRECISION)) as u64;
        };

        if (_delta_in > amount_in) {
            let delta_out_u128 = _delta_out as u128;
            let amount_in_u128 = amount_in as u128;
            let delta_in_u128 = _delta_in as u128;
            _delta_out = ((delta_out_u128 * amount_in_u128) / delta_in_u128) as u64;
            _delta_in = amount_in;
        };

        (_delta_out, _delta_in)
    }

    // Claim accumulated fees
    public entry fun claim_fees<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        position: &mut Position,
        ctx: &mut sui::tx_context::TxContext
    ) {
        assert!(position.pool_id == sui::object::id_address(pool), EPositionNotFound);
        update_position_fees(pool, position);

        let sender = sui::tx_context::sender(ctx);
        if (position.fee_owed_x > 0) {
            let coin_x = coin::from_balance(balance::split(&mut pool.fee_balance_x, position.fee_owed_x), ctx);
            sui::transfer::public_transfer(coin_x, sender);
            position.fee_owed_x = 0;
        };
        if (position.fee_owed_y > 0) {
            let coin_y = coin::from_balance(balance::split(&mut pool.fee_balance_y, position.fee_owed_y), ctx);
            sui::transfer::public_transfer(coin_y, sender);
            position.fee_owed_y = 0;
        };
    }

    // Claim platform fees
    #[allow(unused_mut_parameter)]
    public entry fun claim_platform_fees<X, Y>(
        _cap: &AdminCap,
        pool: &mut LiquidityPool<X, Y>,
        ctx: &mut sui::tx_context::TxContext
    ) {
        let total_platform_fees_x = balance::value(&pool.platform_fee_x);
        let total_platform_fees_y = balance::value(&pool.platform_fee_y);

        if (total_platform_fees_x > 0) {
            let coin_x = coin::from_balance(balance::split(&mut pool.platform_fee_x, total_platform_fees_x), ctx);
            sui::transfer::public_transfer(coin_x, sui::tx_context::sender(ctx));
        };
        if (total_platform_fees_y > 0) {
            let coin_y = coin::from_balance(balance::split(&mut pool.platform_fee_y, total_platform_fees_y), ctx);
            sui::transfer::public_transfer(coin_y, sui::tx_context::sender(ctx));
        };
    }

    // Update 24-hour metrics
    fun update_metrics<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        volume: u64,
        fee: u64,
        clock: &Clock
    ) {
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

    // Query functions
    public fun get_pool_info<X, Y>(pool: &LiquidityPool<X, Y>): (u64, u64, u64, u32, u128, u64, u64) {
        (
            balance::value(&pool.reserve_x),
            balance::value(&pool.reserve_y),
            pool.fee_rate,
            pool.current_tick,
            pool.current_sqrt_price,
            pool.volume_24h,
            pool.fees_24h
        )
    }

    public fun get_position_info(position: &Position): (u32, u32, u128, u64, u64) {
        (
            position.tick_lower,
            position.tick_upper,
            position.liquidity,
            position.fee_owed_x,
            position.fee_owed_y
        )
    }

    public fun get_tvl(registry: &PoolRegistry): u64 {
        registry.total_tvl
    }
}