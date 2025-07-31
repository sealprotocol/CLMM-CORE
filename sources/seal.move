#[allow(unused_use, duplicate_alias)]
module seal::seal {
    use std::option::some;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url;
    use sui::url::Url;

    // One-time witness for Seal token
    public struct SEAL has drop {}

    // Initialize the Seal token
    fun init(witness: SEAL, ctx: &mut TxContext) {
        let url = url::new_unsafe_from_bytes(b"https://bafybeify7qy7bwe5u5qpt4fizp7eumd7we6ikxgg7f62duftday74pidpy.ipfs.w3s.link/SEAL%20LOGO.jpg");
        let pic = some<Url>(url);
        let (mut treasury_cap, metadata) = coin::create_currency(
            witness,
            9, // Decimals
            b"SEAL", // Symbol
            b"Seal Token", // Name
            b"Native token for the Seal DEX", // Description
            pic, // Icon URL
            ctx
        );
        transfer::public_freeze_object(metadata);
        // Mint 100 billion units (100 SEAL with 9 decimals = 100 * 10^9)
        let coin = coin::mint(&mut treasury_cap, 100_000_000_00_000_000_000, ctx);
        transfer::public_transfer(coin, tx_context::sender(ctx));
        // Destroy treasury cap by transferring to a non-recoverable address
        transfer::public_transfer(treasury_cap, @0x0);
    }
}