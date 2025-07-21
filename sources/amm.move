#[allow(unused_variable, unused_use, duplicate_alias, deprecated_usage)]
module amm::amm {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::type_name::{Self, TypeName};
    use std::vector;

    // Error codes
    const EInsufficientLiquidity: u64 = 0; // Insufficient pool reserves or zero output
    const EInvalidAmount: u64 = 1; // Invalid input amount (≤ 0)
    const EPoolAlreadyExists: u64 = 2; // Pool already exists
    const EInsufficientBalance: u64 = 3; // Output exceeds pool reserves
    const EInvalidFee: u64 = 4; // Invalid fee rate
    const EInvalidTokenPair: u64 = 5; // Tokens must be different
    const EInvalidRatio: u64 = 6; // Liquidity addition does not match pool ratio
    const ENoLiquidity: u64 = 7; // User has no liquidity in the pool
    const EInvalidTimestamp: u64 = 8; // Invalid timestamp for metrics
    const ENotAdmin: u64 = 9; // Caller is not the admin

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
        fee_balance_x: Balance<X>, // Accumulated fees for LPs
        fee_balance_y: Balance<Y>,
        platform_fee_x: Balance<X>, // Accumulated fees for DEX platform
        platform_fee_y: Balance<Y>,
        volume_24h: u64, // 24-hour trading volume (in token X)
        fees_24h: u64, // 24-hour fees (in token X)
        last_update: u64, // Last timestamp for 24h metrics
    }

    // Pool Registry
    public struct PoolRegistry has key, store {
        id: UID,
        pools: vector<PoolInfo>,
        total_tvl: u64, // Total Value Locked in token X (or base token)
    }

    // Pool metadata
    public struct PoolInfo has store, copy, drop {
        token_x: TypeName,
        token_y: TypeName,
        pool_addr: address,
        fee_rate: u64,
    }

    // Initialize module
    fun init(ctx: &mut TxContext) {
        let registry = PoolRegistry {
            id: object::new(ctx),
            pools: vector::empty(),
            total_tvl: 0,
        };
        transfer::public_share_object(registry);

        // Create and transfer AdminCap to the deployer
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // Create a new liquidity pool
    public entry fun create_pool<X, Y>(
        registry: &mut PoolRegistry,
        fee_rate: u64,
        ctx: &mut TxContext
    ) {
        // Allow fee rates: 0.001% (0.1 bp), 0.01% (1 bp), 0.05% (5 bp), 0.2% (20 bp), 0.25% (25 bp), 1% (100 bp), 2% (200 bp)
        assert!(
            fee_rate == 0 || fee_rate == 1 || fee_rate == 5 || fee_rate == 20 || fee_rate == 25 || fee_rate == 100 || fee_rate == 200,
            EInvalidFee
        );
        assert!(type_name::get<X>() != type_name::get<Y>(), EInvalidTokenPair);

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
            id: object::new(ctx),
            reserve_x: balance::zero<X>(),
            reserve_y: balance::zero<Y>(),
            fee_rate,
            total_liquidity: 0,
            user_shares: table::new(ctx),
            fee_balance_x: balance::zero<X>(),
            fee_balance_y: balance::zero<Y>(),
            platform_fee_x: balance::zero<X>(),
            platform_fee_y: balance::zero<Y>(),
            volume_24h: 0,
            fees_24h: 0,
            last_update: 0,
        };
        let pool_addr = object::id_address(&pool);

        let pool_info = PoolInfo {
            token_x: type_name::get<X>(),
            token_y: type_name::get<Y>(),
            pool_addr,
            fee_rate,
        };
        vector::push_back(&mut registry.pools, pool_info);

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

        // Update TVL (assuming token X is the base token for simplicity)
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
        assert!(user_liquidity >= amount, EInsufficientLiquidity);

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
        ctx: &mut TxContext
    ) {
        let total_platform_fees_x = balance::value(&pool.platform_fee_x);
        let total_platform_fees_y = balance::value(&pool.platform_fee_y);

        if (total_platform_fees_x > 0) {
            let coin_x = coin::from_balance(balance::split(&mut pool.platform_fee_x, total_platform_fees_x), ctx);
            transfer::public_transfer(coin_x, tx_context::sender(ctx));
        };
        if (total_platform_fees_y > 0) {
            let coin_y = coin::from_balance(balance::split(&mut pool.platform_fee_y, total_platform_fees_y), ctx);
            transfer::public_transfer(coin_y, tx_context::sender(ctx));
        }
    }

    // Swap X to Y
    public entry fun swap<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_in: Coin<X>,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
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
        let platform_fee = (fee_amount * 20) / 100; // 20% to platform
        let lp_fee = fee_amount - platform_fee; // 80% to LPs

        let mut balance_in = coin::into_balance(coin_in);
        let mut fee_balance = balance::split(&mut balance_in, (fee_amount as u64));
        let platform_fee_balance = balance::split(&mut fee_balance, (platform_fee as u64));
        let lp_fee_balance = fee_balance;

        balance::join(&mut pool.platform_fee_x, platform_fee_balance);
        balance::join(&mut pool.fee_balance_x, lp_fee_balance);
        balance::join(&mut pool.reserve_x, balance_in);
        let coin_out = coin::from_balance(balance::split(&mut pool.reserve_y, (amount_out as u64)), ctx);
        transfer::public_transfer(coin_out, tx_context::sender(ctx));

        update_metrics(pool, amount_in, (fee_amount as u64), clock);
    }

    // Swap Y to X
    public entry fun swap_reverse<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_in: Coin<Y>,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
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
        let platform_fee = (fee_amount * 20) / 100; // 20% to platform
        let lp_fee = fee_amount - platform_fee; // 80% to LPs

        let mut balance_in = coin::into_balance(coin_in);
        let mut fee_balance = balance::split(&mut balance_in, (fee_amount as u64));
        let platform_fee_balance = balance::split(&mut fee_balance, (platform_fee as u64));
        let lp_fee_balance = fee_balance;

        balance::join(&mut pool.platform_fee_y, platform_fee_balance);
        balance::join(&mut pool.fee_balance_y, lp_fee_balance);
        balance::join(&mut pool.reserve_y, balance_in);
        let coin_out = coin::from_balance(balance::split(&mut pool.reserve_x, (amount_out as u64)), ctx);
        transfer::public_transfer(coin_out, tx_context::sender(ctx));

        update_metrics(pool, amount_in, (fee_amount as u64), clock);
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

    // Query functions

    // Get pool reserves and fees
    public fun get_pool_info<X, Y>(pool: &LiquidityPool<X, Y>): (u64, u64, u64, u64, u64) {
        (
            balance::value(&pool.reserve_x),
            balance::value(&pool.reserve_y),
            pool.fee_rate,
            pool.volume_24h,
            pool.fees_24h
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

    // Estimate APR (simplified, assumes token X is base for valuation)
    public fun estimate_apr<X, Y>(pool: &LiquidityPool<X, Y>): u64 {
        let fees_24h = pool.fees_24h;
        let reserve_x = balance::value(&pool.reserve_x);
        if (reserve_x == 0) return 0;
        // Annualize daily fees: (fees_24h / reserve_x) * 365 * 100
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