module reef_coin::reef;

use sui::coin::{Self, TreasuryCap};

public struct REEF() has drop;

public struct Minter has key {
    id: UID,
    treasury_cap: TreasuryCap<REEF>,
}

fun init(reef: REEF, ctx: &mut TxContext) {
    let (treasury_cap, coin_metadata) = coin::create_currency(
        reef,
        9,
        b"REEF",
        b"Reef Coin",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_share_object(coin_metadata);

    transfer::share_object(Minter { id: object::new(ctx), treasury_cap })
}


public fun mint(minter: &mut Minter, amount: u64, ctx: &mut TxContext) {
    mint_to(minter, amount, ctx.sender(), ctx)
}

public fun mint_to(minter: &mut Minter, amount: u64, addr: address, ctx: &mut TxContext) {
    transfer::public_transfer(minter.treasury_cap.mint(amount, ctx), addr)
}