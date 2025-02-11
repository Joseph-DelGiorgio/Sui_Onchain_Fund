module 0x0::onchain_fund {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext, epoch, sender};
    use sui::coin::{
        Self,
        Coin,
        TreasuryCap,
        create_currency,
        value,
        mint,
        burn,
        total_supply,
        into_balance,
        from_balance
    };
    use sui::balance::{Self, Balance, zero, join, split};
    use sui::table::{Self, Table, contains, add, borrow_mut};
    use sui::sui::SUI;
    use sui::event;
    use std::string::{Self, String};
    use std::option;

    // Error codes
    const EInsufficientBalance: u64 = 0;
    const EUnauthorized: u64 = 1;
    const EInvalidFeeParameter: u64 = 2;

    // Fund token
    struct FundToken has drop {}

    // Main Fund struct
    struct Fund has key {
        id: UID,
        treasury_cap: TreasuryCap<FundToken>,
        asset_vault: Table<String, Balance<SUI>>,
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

    // Events
    struct DepositEvent has copy, drop {
        depositor: address,
        amount: u64,
    }

    struct WithdrawEvent has copy, drop {
        withdrawer: address,
        amount: u64,
    }

    // Initialize the fund
    fun init(ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            FundToken {},
            9,
            b"FUND",
            b"Investment Fund Token",
            b"An on-chain investment fund token",
            option::none(),
            ctx
        );

        let fund = Fund {
            id: object::new(ctx),
            treasury_cap,
            asset_vault: table::new(ctx),
            total_nav: 0,
            fee_config: FeeSchedule {
                management_fee_bps: 100,   // 1%
                performance_fee_bps: 2000, // 20%
                last_fee_collection: epoch(ctx),
            },
            manager: sender(ctx),
        };

        transfer::share_object(fund);
        transfer::public_transfer(metadata, sender(ctx));
    }

    // Deposit SUI into the fund
    public entry fun deposit(
        fund: &mut Fund,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let deposit_value = coin::value(&payment);

        // Reinitialize the key to pass an owned String.
        let key1 = string::utf8(b"SUI");
        if (!table::contains(&fund.asset_vault, key1)) {
            let key2 = string::utf8(b"SUI");
            table::add(&mut fund.asset_vault, key2, zero<SUI>());
        };

        let key3 = string::utf8(b"SUI");
        let balance_ref = table::borrow_mut(&mut fund.asset_vault, key3);
        join(balance_ref, into_balance(payment));

        let total_supply = coin::total_supply(&fund.treasury_cap);
        let shares_to_mint = if (total_supply == 0) {
            deposit_value
        } else {
            (deposit_value * total_supply) / fund.total_nav
        };

        fund.total_nav = fund.total_nav + deposit_value;
        let shares = coin::mint(&mut fund.treasury_cap, shares_to_mint, ctx);
        transfer::public_transfer(shares, sender(ctx));

        event::emit(DepositEvent {
            depositor: sender(ctx),
            amount: deposit_value,
        });
    }

    // Withdraw from the fund
    public entry fun withdraw(
        fund: &mut Fund,
        shares: Coin<FundToken>,
        ctx: &mut TxContext
    ) {
        let shares_value = coin::value(&shares);
        let total_supply = coin::total_supply(&fund.treasury_cap);
        let withdraw_amount = (shares_value * fund.total_nav) / total_supply;

        coin::burn(&mut fund.treasury_cap, shares);
        fund.total_nav = fund.total_nav - withdraw_amount;

        let key1 = string::utf8(b"SUI");
        let balance_ref = table::borrow_mut(&mut fund.asset_vault, key1);
        let withdrawn = split(balance_ref, withdraw_amount);
        
        let withdrawn_coin = coin::from_balance(withdrawn, ctx);
        transfer::public_transfer(withdrawn_coin, sender(ctx));

        event::emit(WithdrawEvent {
            withdrawer: sender(ctx),
            amount: withdraw_amount,
        });
    }

    // Collect management and performance fees (only callable by manager)
    public entry fun collect_fees(fund: &mut Fund, ctx: &mut TxContext) {
        assert!(sender(ctx) == fund.manager, EUnauthorized);

        let current_epoch = epoch(ctx);
        let epochs_passed = current_epoch - fund.fee_config.last_fee_collection;

        let management_fee = (fund.total_nav * fund.fee_config.management_fee_bps * epochs_passed) / (10000 * 365);
        let performance_fee = 0; // Implement performance fee calculation based on your requirements

        let total_fee = management_fee + performance_fee;
        assert!(total_fee <= fund.total_nav, EInsufficientBalance);

        let key1 = string::utf8(b"SUI");
        let balance_ref = table::borrow_mut(&mut fund.asset_vault, key1);
        let fee_balance = split(balance_ref, total_fee);
        
        let fee_coin = coin::from_balance(fee_balance, ctx);
        transfer::public_transfer(fee_coin, fund.manager);

        fund.total_nav = fund.total_nav - total_fee;
        fund.fee_config.last_fee_collection = current_epoch;
    }

    // Update fee parameters (only callable by manager)
    public entry fun update_fees(
        fund: &mut Fund,
        new_management_fee_bps: u64,
        new_performance_fee_bps: u64,
        ctx: &mut TxContext
    ) {
        assert!(sender(ctx) == fund.manager, EUnauthorized);
        assert!(new_management_fee_bps <= 1000, EInvalidFeeParameter); // Max 10%
        assert!(new_performance_fee_bps <= 3000, EInvalidFeeParameter); // Max 30%

        fund.fee_config.management_fee_bps = new_management_fee_bps;
        fund.fee_config.performance_fee_bps = new_performance_fee_bps;
    }
}