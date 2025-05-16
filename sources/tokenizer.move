module tokenizer::TOKENIZER {
    // ===== Imports =====
    
    // Sui standard imports
    use sui::coin::{Self, TreasuryCap};
    use sui::url::{Self};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    
    // ART20 imports
    use artinals::ART20::{Self, CollectionCap, UserBalance};
    
    // ===== Error Constants =====
    
    const E_COLLECTION_MISMATCH: u64 = 1;
    const E_COLLECTION_NOT_ACTIVE: u64 = 2;
    const E_INVALID_MINT_AMOUNT: u64 = 3;
    const E_INVALID_TOKEN_RATIO: u64 = 4;
    const E_COLLECTION_ALREADY_REGISTERED: u64 = 5;
    const E_COLLECTION_NOT_REGISTERED: u64 = 6;
    const E_OVERFLOW: u64 = 8;
    const E_NOT_CREATOR: u64 = 10;
    const E_MAX_SUPPLY_EXCEEDED: u64 = 11;
    
    // ===== Constants =====
    const MAX_U64: u64 = 18446744073709551615;
    const MAX_SUPPLY: u64 = 1000000000000000000; // 1 quintillion (adjust based on decimals)
    
    // ===== One-Time-Witness =====
    /// One-Time-Witness for the module
    public struct TOKENIZER has drop {}
    
    // ===== Core Data Structures =====
    
    /// Manages the relationship between CICC tokens and ART20 NFTs
    public struct TokenizedCollection has key, store {
        id: UID,
        collection_id: ID,
        tokens_per_nft: u64,
        total_nfts: u64,
        total_tokens: u64,
        creator: address,
        is_active: bool,
        creation_time: u64
    }
    
    /// Registry for all tokenized collections
    public struct TokenRegistry has key {
        id: UID,
        // Collection ID -> TokenizedCollection ID mapping
        collections: Table<ID, ID>,
        // Total number of collections registered
        collection_count: u64,
        // Total CICC tokens minted through collections
        total_backed_tokens: u64
    }
    
    // ===== Events =====
    
    /// Emitted when a new tokenized collection is created
    public struct TokenizedCollectionCreated has copy, drop {
        collection_id: ID,
        tokenized_collection_id: ID,
        tokens_per_nft: u64,
        initial_nft_mint: u64,
        total_tokens: u64,
        creator: address,
        timestamp: u64
    }
    
    /// Emitted when additional NFTs and tokens are minted
    public struct TokenizedCollectionExtended has copy, drop {
        collection_id: ID,
        tokenized_collection_id: ID,
        additional_nfts: u64,
        additional_tokens: u64,
        new_total_nfts: u64,
        new_total_tokens: u64,
        timestamp: u64
    }
    
    /// Emitted when minting is frozen for a collection
    public struct TokenizedCollectionFrozen has copy, drop {
        collection_id: ID,
        tokenized_collection_id: ID,
        total_nfts: u64,
        total_tokens: u64,
        timestamp: u64
    }
    
    
    /// Emitted when token ratio is updated
    public struct TokenRatioUpdated has copy, drop {
        collection_id: ID,
        tokenized_collection_id: ID,
        old_ratio: u64,
        new_ratio: u64,
        updater: address,
        timestamp: u64
    }

    // ===== Module Initialization =====
    
    fun init(witness: TOKENIZER, ctx: &mut TxContext) {
        // Create the CICC currency
        let (mut treasury_cap, metadata) = coin::create_currency(
            witness,
            9, // 9 decimals 
            b"Default Symbol", 
            b"Default Token Name", 
            b"Tokenized representation of assets backed by ART20 NFTs", 
            option::some(url::new_unsafe_from_bytes(b"https://salmon-accused-puma-149.mypinata.cloud/ipfs/bafkreigswgfmfam7x5dguedjmxeptkogbvf4qfrx45fqcruda6afmhdx4y?pinataGatewayToken=Nc4R8TH9sXtjJQUiqvn_ZXvRnNYOlp6eH8lT7JTr0zEUEZV2BjEMU-81HiF2dy5x")), 
            ctx
        );
        
        // Create initial supply (100,000 tokens)
        let initial_supply = coin::mint(&mut treasury_cap, 100000000000000, ctx); // 100,000 with 9 decimals
        
        // Create token registry
        let registry = TokenRegistry {
            id: object::new(ctx),
            collections: table::new(ctx),
            collection_count: 0,
            total_backed_tokens: 0
        };
        
        // Share registry
        transfer::share_object(registry);
        
        // Transfer CICC supply and treasury cap
        transfer::public_transfer(initial_supply, tx_context::sender(ctx));
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
        transfer::public_freeze_object(metadata);
    }
    
    // ===== Core Functions =====
    
    /// Tokenize an existing ART20 collection
    public entry fun tokenize_existing_collection(
    collection_cap: &CollectionCap,
    tokens_per_nft: u64,
    registry: &mut TokenRegistry,
    treasury_cap: &mut TreasuryCap<TOKENIZER>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Replace admin verification with collection ownership verification
    let sender = tx_context::sender(ctx);
    let collection_creator = ART20::get_collection_creator(collection_cap);
    assert!(sender == collection_creator, E_NOT_CREATOR);
        
        // Get collection info
        let collection_id = ART20::get_collection_cap_id(collection_cap);
        let initial_nft_mint = ART20::get_collection_current_supply(collection_cap);
        
        // Validate parameters
        assert!(initial_nft_mint > 0, E_INVALID_MINT_AMOUNT);
        assert!(tokens_per_nft > 0, E_INVALID_TOKEN_RATIO);
        
        // Check collection is not already tokenized
        assert!(!table::contains(&registry.collections, collection_id), E_COLLECTION_ALREADY_REGISTERED);
        
        // Calculate total tokens to mint
        let total_tokens = safe_mul(initial_nft_mint, tokens_per_nft);
        
        // Check if total supply would exceed maximum
        assert!(registry.total_backed_tokens + total_tokens <= MAX_SUPPLY, E_MAX_SUPPLY_EXCEEDED);
        
        // Create tokenized collection record
        let tokenized_collection = TokenizedCollection {
            id: object::new(ctx),
            collection_id,
            tokens_per_nft,
            total_nfts: initial_nft_mint,
            total_tokens,
            creator: tx_context::sender(ctx),
            is_active: true,
            creation_time: clock::timestamp_ms(clock)
        };
        
        // Register tokenized collection
        let tokenized_collection_id = object::uid_to_inner(&tokenized_collection.id);
        table::add(
            &mut registry.collections, 
            collection_id, 
            tokenized_collection_id
        );
        
        // Update registry stats
        registry.collection_count = registry.collection_count + 1;
        registry.total_backed_tokens = registry.total_backed_tokens + total_tokens;
        
        // Mint CICC tokens
        let minted_tokens = coin::mint(treasury_cap, total_tokens, ctx);
        
        // Emit event
        event::emit(TokenizedCollectionCreated {
            collection_id,
            tokenized_collection_id,
            tokens_per_nft,
            initial_nft_mint,
            total_tokens,
            creator: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock)
        });
        
        // Transfer tokens to creator
        transfer::public_transfer(minted_tokens, tx_context::sender(ctx));
        transfer::share_object(tokenized_collection);
    }
    
    /// Mint additional NFTs and tokens for an existing tokenized collection
    public entry fun mint_additional(
    registry: &mut TokenRegistry,
    tokenized_collection: &mut TokenizedCollection,
    collection_cap: &mut CollectionCap,
    treasury_cap: &mut TreasuryCap<TOKENIZER>,
    amount: u64,
    counter: &mut ART20::TokenIdCounter,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Verify collection creator instead of admin
    let sender = tx_context::sender(ctx);
    let collection_creator = ART20::get_collection_creator(collection_cap);
    assert!(sender == collection_creator, E_NOT_CREATOR);
        
        // Verify collection matches
        assert!(tokenized_collection.collection_id == ART20::get_collection_cap_id(collection_cap), E_COLLECTION_MISMATCH);
        
        // Verify collection is active
        assert!(tokenized_collection.is_active, E_COLLECTION_NOT_ACTIVE);
        
        // Validate parameters
        assert!(amount > 0, E_INVALID_MINT_AMOUNT);
        
        // Calculate tokens to mint
        let tokens_to_mint = safe_mul(amount, tokenized_collection.tokens_per_nft);
        
        // Check if total supply would exceed maximum
        assert!(registry.total_backed_tokens + tokens_to_mint <= MAX_SUPPLY, E_MAX_SUPPLY_EXCEEDED);
        
        // Create user balance vector
        let user_balances = vector::empty<UserBalance>();
        
        // Mint additional NFTs
        ART20::mint_additional_art20(
            collection_cap,
            amount,
            counter,
            user_balances,
            clock,
            ctx
        );
        
        // Mint corresponding CICC tokens
        let minted_tokens = coin::mint(treasury_cap, tokens_to_mint, ctx);
        
        // Update tokenized collection record
        tokenized_collection.total_nfts = tokenized_collection.total_nfts + amount;
        tokenized_collection.total_tokens = tokenized_collection.total_tokens + tokens_to_mint;
        
        // Update registry stats
        registry.total_backed_tokens = registry.total_backed_tokens + tokens_to_mint;
        
        // Emit event
        event::emit(TokenizedCollectionExtended {
            collection_id: tokenized_collection.collection_id,
            tokenized_collection_id: object::uid_to_inner(&tokenized_collection.id),
            additional_nfts: amount,
            additional_tokens: tokens_to_mint,
            new_total_nfts: tokenized_collection.total_nfts,
            new_total_tokens: tokenized_collection.total_tokens,
            timestamp: clock::timestamp_ms(clock)
        });
        
        // Transfer tokens to creator
        transfer::public_transfer(minted_tokens, tx_context::sender(ctx));
    }
    
    /// Freeze minting for a tokenized collection
    public entry fun freeze_minting(
    tokenized_collection: &mut TokenizedCollection,
    collection_cap: &mut CollectionCap,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Verify collection creator
    let sender = tx_context::sender(ctx);
    let collection_creator = ART20::get_collection_creator(collection_cap);
    assert!(sender == collection_creator, E_NOT_CREATOR);
        
        // Verify collection matches
        assert!(tokenized_collection.collection_id == ART20::get_collection_cap_id(collection_cap), E_COLLECTION_MISMATCH);
        
        // Verify collection is active
        assert!(tokenized_collection.is_active, E_COLLECTION_NOT_ACTIVE);
        
        // Freeze collection minting
        ART20::freeze_minting(collection_cap, ctx);
        
        // Mark tokenized collection as inactive
        tokenized_collection.is_active = false;
        
        // Emit event
        event::emit(TokenizedCollectionFrozen {
            collection_id: tokenized_collection.collection_id,
            tokenized_collection_id: object::uid_to_inner(&tokenized_collection.id),
            total_nfts: tokenized_collection.total_nfts,
            total_tokens: tokenized_collection.total_tokens,
            timestamp: clock::timestamp_ms(clock)
        });
    }
    
    
    
    /// Update the token ratio for a tokenized collection (only affects future mints)
    public entry fun update_token_ratio(
    tokenized_collection: &mut TokenizedCollection,
    collection_cap: &CollectionCap,
    new_ratio: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Verify collection creator
    let sender = tx_context::sender(ctx);
    let collection_creator = ART20::get_collection_creator(collection_cap);
    assert!(sender == collection_creator, E_NOT_CREATOR);
    
    // Also verify they're the creator of the tokenized collection
    assert!(sender == tokenized_collection.creator, E_NOT_CREATOR);
        
        // Verify collection is active
        assert!(tokenized_collection.is_active, E_COLLECTION_NOT_ACTIVE);
        
        // Validate parameters
        assert!(new_ratio > 0, E_INVALID_TOKEN_RATIO);
        
        // Store old ratio for event
        let old_ratio = tokenized_collection.tokens_per_nft;
        
        // Update ratio
        tokenized_collection.tokens_per_nft = new_ratio;
        
        // Emit event
        event::emit(TokenRatioUpdated {
            collection_id: tokenized_collection.collection_id,
            tokenized_collection_id: object::uid_to_inner(&tokenized_collection.id),
            old_ratio,
            new_ratio,
            updater: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock)
        });
    }
    
    // ===== Utility Functions =====
    
    /// Safe multiplication preventing overflow
    fun safe_mul(a: u64, b: u64): u64 {
        if (a == 0 || b == 0) {
            return 0
        };
        assert!(a <= MAX_U64 / b, E_OVERFLOW);
        a * b
    }
    
    // ===== View Functions =====
    
    /// Get basic information about a tokenized collection
    public fun get_collection_info(tokenized_collection: &TokenizedCollection): (ID, u64, u64, u64, address, bool, u64) {
        (
            tokenized_collection.collection_id,
            tokenized_collection.tokens_per_nft,
            tokenized_collection.total_nfts,
            tokenized_collection.total_tokens,
            tokenized_collection.creator,
            tokenized_collection.is_active,
            tokenized_collection.creation_time
        )
    }
    
    /// Get registry statistics
    public fun get_registry_stats(registry: &TokenRegistry): (u64, u64) {
        (registry.collection_count, registry.total_backed_tokens)
    }
    
    /// Check if a collection is registered
    public fun is_collection_registered(registry: &TokenRegistry, collection_id: ID): bool {
        table::contains(&registry.collections, collection_id)
    }
    
    /// Get tokenized collection ID for a collection
    public fun get_tokenized_collection_id(registry: &TokenRegistry, collection_id: ID): ID {
        assert!(table::contains(&registry.collections, collection_id), E_COLLECTION_NOT_REGISTERED);
        *table::borrow(&registry.collections, collection_id)
    }
    
    /// Get token/NFT ratio for a collection
    public fun get_tokens_per_nft(tokenized_collection: &TokenizedCollection): u64 {
        tokenized_collection.tokens_per_nft
    }
    
    /// Check if a collection is active
    public fun is_collection_active(tokenized_collection: &TokenizedCollection): bool {
        tokenized_collection.is_active
    }
    
    /// Calculate how many tokens are needed to redeem a specific number of NFTs
    public fun calculate_redemption_cost(tokenized_collection: &TokenizedCollection, nft_count: u64): u64 {
        safe_mul(nft_count, tokenized_collection.tokens_per_nft)
    }
    
    /// Calculate how many NFTs can be redeemed with a specific token amount
    public fun calculate_nfts_redeemable(tokenized_collection: &TokenizedCollection, token_amount: u64): u64 {
        token_amount / tokenized_collection.tokens_per_nft
    }
}