#[allow(duplicate_alias, unused_variable)]
module clmm::xseal {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::dynamic_field as df;
    use std::type_name::{Self, TypeName};

    // Error codes
    const EInvalidStakeAmount: u64 = 100;
    const EInvalidStakeDuration: u64 = 101;
    const ENoStake: u64 = 102;
    const EStakeNotExpired: u64 = 103;
    const EInvalidAmount: u64 = 104;
    const ENotAdmin: u64 = 105;
    const EZeroTotalDeSeal: u64 = 106;

    // Constants
    const ONE_DAY_MS: u64 = 24 * 60 * 60 * 1000; // 1 day in milliseconds
    const FOUR_YEARS_MS: u64 = 4 * 365 * ONE_DAY_MS; // 4 years in milliseconds
    const DEVELOPER_WALLET: address = @0x1234567890abcdef; // Placeholder developer wallet address

    // Admin capability
    public struct AdminCap has key {
        id: UID,
    }

    // Staking pool for Seal tokens
    public struct StakingPool has key, store {
        id: UID,
        total_de_seal: u128, // Total deSeal score
        stakes: Table<address, StakeInfo>, // User stake info
        is_distribution_enabled: bool, // Switch for fee distribution
    }

    // Stake information for each user
    public struct StakeInfo has store, drop {
        amount: u64, // Amount of Seal tokens staked
        de_seal: u128, // Current deSeal score
        start_time: u64, // Stake start timestamp
        duration_ms: u64, // Stake duration in milliseconds
    }

    // Event for staking
    public struct StakeEvent has copy, drop {
        user: address,
        amount: u64,
        duration_ms: u64,
        de_seal: u128,
    }

    // Event for unstaking
    public struct UnstakeEvent has copy, drop {
        user: address,
        amount: u64,
    }

    // Event for fee distribution
    public struct FeeDistributionEvent has copy, drop {
        token_type: TypeName,
        amount: u64,
    }

    // Event for claiming fees
    public struct ClaimFeesEvent has copy, drop {
        user: address,
        token_type: TypeName,
        amount: u64,
    }

    // Initialize the staking pool
    fun init(ctx: &mut TxContext) {
        let staking_pool = StakingPool {
            id: object::new(ctx),
            total_de_seal: 0,
            stakes: table::new(ctx),
            is_distribution_enabled: false,
        };
        transfer::public_share_object(staking_pool);

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // Enable fee distribution (called after TGE)
    public entry fun enable_distribution(_cap: &AdminCap, pool: &mut StakingPool, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == DEVELOPER_WALLET, ENotAdmin);
        pool.is_distribution_enabled = true;
    }

    // Stake Seal tokens
    public entry fun stake(
        pool: &mut StakingPool,
        coin: Coin<seal::seal::SEAL>,
        duration_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&coin);
        assert!(amount > 0, EInvalidStakeAmount);
        assert!(duration_ms >= ONE_DAY_MS && duration_ms <= FOUR_YEARS_MS, EInvalidStakeDuration);

        let sender = tx_context::sender(ctx);
        let start_time = clock::timestamp_ms(clock);
        let years = duration_ms / (365 * ONE_DAY_MS); // Convert duration to years
        let de_seal = (amount as u128) * (years as u128);

        let stake_info = StakeInfo {
            amount,
            de_seal,
            start_time,
            duration_ms,
        };

        if (table::contains(&pool.stakes, sender)) {
            let existing_stake = table::borrow_mut(&mut pool.stakes, sender);
            pool.total_de_seal = pool.total_de_seal - existing_stake.de_seal;
            existing_stake.amount = existing_stake.amount + amount;
            existing_stake.de_seal = existing_stake.de_seal + de_seal;
            existing_stake.start_time = start_time;
            existing_stake.duration_ms = duration_ms;
        } else {
            table::add(&mut pool.stakes, sender, stake_info);
        };

        pool.total_de_seal = pool.total_de_seal + de_seal;

        // Store the staked Seal tokens in dynamic field
        let token_type = type_name::get<clmm::seal::SEAL>();
        let balance = coin::into_balance(coin);
        if (!df::exists_(&pool.id, token_type)) {
            df::add(&mut pool.id, token_type, balance::zero<clmm::seal::SEAL>());
        };
        balance::join(df::borrow_mut(&mut pool.id, token_type), balance);

        event::emit(StakeEvent {
            user: sender,
            amount,
            duration_ms,
            de_seal,
        });
    }

    // Unstake Seal tokens (only after duration expires)
    public entry fun unstake(
        pool: &mut StakingPool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&pool.stakes, sender), ENoStake);

        let stake_info = table::remove(&mut pool.stakes, sender);
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= stake_info.start_time + stake_info.duration_ms, EStakeNotExpired);

        let amount = stake_info.amount;
        pool.total_de_seal = pool.total_de_seal - stake_info.de_seal;

        let token_type = type_name::get<clmm::seal::SEAL>();
        let coin = coin::from_balance(
            balance::split(df::borrow_mut<_, Balance<clmm::seal::SEAL>>(&mut pool.id, token_type), amount),
            ctx
        );
        transfer::public_transfer(coin, sender);

        event::emit(UnstakeEvent {
            user: sender,
            amount,
        });
    }

    // Calculate current deSeal score for a user
    public fun calculate_de_seal(stake_info: &StakeInfo, current_time: u64): u128 {
        if (current_time >= stake_info.start_time + stake_info.duration_ms) {
            return 0
        };
        let elapsed_ms = current_time - stake_info.start_time;
        let remaining_ms = stake_info.duration_ms - elapsed_ms;
        (stake_info.de_seal * (remaining_ms as u128)) / (stake_info.duration_ms as u128)
    }

    // Distribute platform fees to the staking pool
    public entry fun distribute_fees<T>(
        pool: &mut StakingPool,
        coin: Coin<T>,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&coin);
        assert!(amount > 0, EInvalidAmount);

        let token_type = type_name::get<T>();
        let balance = coin::into_balance(coin);
        if (!df::exists_(&pool.id, token_type)) {
            df::add(&mut pool.id, token_type, balance::zero<T>());
        };
        balance::join(df::borrow_mut<_, Balance<T>>(&mut pool.id, token_type), balance);

        event::emit(FeeDistributionEvent {
            token_type,
            amount,
        });
    }

    // Claim accumulated fees for a staker
    public entry fun claim_staker_fees<T>(
        pool: &mut StakingPool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&pool.stakes, sender), ENoStake);

        let stake_info = table::borrow(&pool.stakes, sender);
        let current_time = clock::timestamp_ms(clock);
        let current_de_seal = calculate_de_seal(stake_info, current_time);
        let original_de_seal = stake_info.de_seal; // Store to release immutable borrow

        let token_type = type_name::get<T>();
        if (!df::exists_(&pool.id, token_type)) {
            return
        };

        let total_fees = balance::value(df::borrow<_, Balance<T>>(&pool.id, token_type));
        assert!(pool.total_de_seal > 0, EZeroTotalDeSeal);
        let user_fee = ((current_de_seal as u256) * (total_fees as u256) / (pool.total_de_seal as u256)) as u64;

        if (user_fee > 0) {
            let coin = coin::from_balance(
                balance::split(df::borrow_mut<_, Balance<T>>(&mut pool.id, token_type), user_fee),
                ctx
            );
            transfer::public_transfer(coin, sender);

            event::emit(ClaimFeesEvent {
                user: sender,
                token_type,
                amount: user_fee,
            });
        };

        // Update user's deSeal score
        if (current_de_seal != original_de_seal) {
            let stake_info_mut = table::borrow_mut(&mut pool.stakes, sender);
            pool.total_de_seal = pool.total_de_seal - original_de_seal + current_de_seal;
            stake_info_mut.de_seal = current_de_seal;
        };
    }

    // Get user's current stake info
    public fun get_stake_info(pool: &StakingPool, user: address, clock: &Clock): (u64, u128, u64, u64) {
        if (!table::contains(&pool.stakes, user)) {
            return (0, 0, 0, 0)
        };
        let stake_info = table::borrow(&pool.stakes, user);
        let current_de_seal = calculate_de_seal(stake_info, clock::timestamp_ms(clock));
        (stake_info.amount, current_de_seal, stake_info.start_time, stake_info.duration_ms)
    }

    // Get total deSeal score
    public fun get_total_de_seal(pool: &StakingPool): u128 {
        pool.total_de_seal
    }
}