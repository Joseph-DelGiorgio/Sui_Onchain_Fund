module 0x0::onchain_fund {
    use sui::object::UID;
    use sui::transfer;
    use sui::tx_context::{TxContext, epoch, sender};
    use sui::coin::{
        Coin,
        TreasuryCap,
        create_currency,
        total_supply,
        mint,
        burn,
        into_balance,
        from_balance,
        value
    };
    use sui::balance::{Balance, zero, join, split};
    use sui::table::{contains, add, borrow_mut, new};
    use sui::sui::SUI;
    use sui::event;
    use std::string::{utf8, String};
    use std::option;

    // Error codes
    const EInsufficientBalance: u64 = 0;
    const EUnauthorized: u64 = 1;
    const EInvalidFeeParameter: u64 = 2;

    // One Time Witness: Name must be the module name in uppercase.
    struct ONCHAIN_FUND has drop {}

    // Main Fund struct
    struct Fund has key {
        id: UID,
        treasury_cap: TreasuryCap<ONCHAIN_FUND>,
        asset_vault: sui::table::Table<String, Balance<SUI>>,
        total_nav: u64,
        fee_config: FeeSchedule,
        manager: address,
    }

    // Fee configuration
    struct FeeSchedule has store {
        management_fee_bps: u64,
        performance_fee_bps: u64,
        last_fee_collection: u64,
    }

    // Events for off-chain tracking.
    struct DepositEvent has copy, drop {
        depositor: address,
        amount: u64,
    }

    struct WithdrawEvent has copy, drop {
        withdrawer: address,
        amount: u64,
    }

    // The module initializer.
    // Note that the first parameter must be the one-time witness (ONCHAIN_FUND) supplied automatically at publish.
    fun init(witness: ONCHAIN_FUND, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = create_currency(
            witness,
            9,
            b"FUND",
            b"Investment Fund Token",
            b"An on-chain investment fund token",
            option::none(),
            ctx
        );
        let fund = Fund {
            id: sui::object::new(ctx),
            treasury_cap,
            asset_vault: new(ctx),
            total_nav: 0,
            fee_config: FeeSchedule {
                management_fee_bps: 100,   // 1%
                performance_fee_bps: 2000, // 20%
                last_fee_collection: epoch(ctx),
            },
            manager: sender(ctx),
        };
        transfer::share_object(fund);
        transfer::public_freeze_object(metadata);
    }

    // Deposit SUI into the fund.
    public entry fun deposit(
        fund: &mut Fund,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let deposit_value = value(&payment);
        let key = utf8(b"SUI");
        if (!contains(&fund.asset_vault, key)) {
            add(&mut fund.asset_vault, key, zero<SUI>());
        };
        let balance_ref = borrow_mut(&mut fund.asset_vault, key);
        join(balance_ref, into_balance(payment));
        let current_supply = total_supply(&fund.treasury_cap);
        let shares_to_mint = if (current_supply == 0) {
            deposit_value
        } else {
            (deposit_value * current_supply) / fund.total_nav
        };
        fund.total_nav = fund.total_nav + deposit_value;
        let shares = mint(&mut fund.treasury_cap, shares_to_mint, ctx);
        transfer::public_transfer(shares, sender(ctx));
        event::emit(DepositEvent {
            depositor: sender(ctx),
            amount: deposit_value,
        });
    }

    // Withdraw SUI from the fund.
    public entry fun withdraw(
        fund: &mut Fund,
        shares: Coin<ONCHAIN_FUND>,
        ctx: &mut TxContext
    ) {
        let shares_value = value(&shares);
        let current_supply = total_supply(&fund.treasury_cap);
        let withdraw_amount = (shares_value * fund.total_nav) / current_supply;
        burn(&mut fund.treasury_cap, shares);
        fund.total_nav = fund.total_nav - withdraw_amount;
        let key = utf8(b"SUI");
        let balance_ref = borrow_mut(&mut fund.asset_vault, key);
        let withdrawn: Balance<SUI> = split(balance_ref, withdraw_amount);
        let withdrawn_coin: Coin<SUI> = from_balance(withdrawn, ctx);
        transfer::public_transfer(withdrawn_coin, sender(ctx));
        event::emit(WithdrawEvent {
            withdrawer: sender(ctx),
            amount: withdraw_amount,
        });
    }

    // Collect management and performance fees (restricted to the fund manager).
    public entry fun collect_fees(fund: &mut Fund, ctx: &mut TxContext) {
        assert!(sender(ctx) == fund.manager, EUnauthorized);
        let current_epoch = epoch(ctx);
        let epochs_passed = current_epoch - fund.fee_config.last_fee_collection;
        let management_fee = (fund.total_nav * fund.fee_config.management_fee_bps * epochs_passed)
            / (10000 * 365);
        let performance_fee = 0; // Implement performance fee calculation as needed.
        let total_fee = management_fee + performance_fee;
        assert!(total_fee <= fund.total_nav, EInsufficientBalance);
        let key = utf8(b"SUI");
        let balance_ref = borrow_mut(&mut fund.asset_vault, key);
        let fee_balance: Balance<SUI> = split(balance_ref, total_fee);
        let fee_coin: Coin<SUI> = from_balance(fee_balance, ctx);
        transfer::public_transfer(fee_coin, fund.manager);
        fund.total_nav = fund.total_nav - total_fee;
        fund.fee_config.last_fee_collection = current_epoch;
    }

    // Update fee parameters (restricted to the fund manager).
    public entry fun update_fees(
        fund: &mut Fund,
        new_management_fee_bps: u64,
        new_performance_fee_bps: u64,
        ctx: &mut TxContext
    ) {
        assert!(sender(ctx) == fund.manager, EUnauthorized);
        assert!(new_management_fee_bps <= 1000, EInvalidFeeParameter);
        assert!(new_performance_fee_bps <= 3000, EInvalidFeeParameter);
        fund.fee_config.management_fee_bps = new_management_fee_bps;
        fund.fee_config.performance_fee_bps = new_performance_fee_bps;
    }
}
