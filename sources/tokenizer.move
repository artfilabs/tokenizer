module tokenizer::Tokenizer {
    // ===== Imports =====
    
    // Sui standard imports
    use sui::coin::{Self, TreasuryCap};
    use sui::url::{Self, Url};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::package;
    use std::string::{Self, String};

    
    // ART20 imports
    use artinals::ART20::{Self,CollectionCap, UserBalance, TokenIdCounter};
    
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
    const E_INVALID_DECIMALS: u64 = 12;
    
    // ===== Constants =====
    const MAX_U64: u64 = 18446744073709551615;
    const DEFAULT_MAX_SUPPLY: u64 = 1000000000000000000; // 1 quintillion (adjust based on decimals)
    
    // ===== One-Time-Witness =====
    /// One-Time-Witness for the module
    public struct TOKENIZER has drop {}
    
    // ===== Core Data Structures =====
    
    /// Publisher capability for tokenizer module - only needed for module upgrades
    public struct TokenizerPublisher has key, store {
        id: UID
    }
    
    /// Represents a token created through this platform
    public struct TokenInfo has key, store {
        id: UID,
        name: String,
        symbol: String,
        description: String,
        icon_url: Url,
        decimals: u8,
        max_supply: u64,
        creator: address
    }
    
    /// Manages the relationship between tokenized coins and ART20 NFTs
    public struct TokenizedCollection<phantom T> has key, store {
        id: UID,
        collection_id: ID,
        token_info_id: ID,
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
        // Token Type ID -> Collection ID -> TokenizedCollection ID mapping
        collections: Table<vector<u8>, Table<ID, ID>>,
        // Total number of collections registered by token type
        collection_counts: Table<vector<u8>, u64>,
        // Total tokens minted through collections by token type
        total_backed_tokens: Table<vector<u8>, u64>
    }
    
    // ===== Events =====
    
    /// Emitted when a new token is created
    public struct TokenCreated has copy, drop {
        token_info_id: ID,
        name: String,
        symbol: String,
        decimals: u8,
        max_supply: u64,
        creator: address,
        timestamp: u64
    }
    
    /// Emitted when a new tokenized collection is created
    public struct TokenizedCollectionCreated has copy, drop {
        collection_id: ID,
        tokenized_collection_id: ID,
        token_type: vector<u8>,
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
        token_type: vector<u8>,
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
        token_type: vector<u8>,
        total_nfts: u64,
        total_tokens: u64,
        timestamp: u64
    }
    
    // Emitted when tokens are redeemed for NFTs
    // public struct TokensRedeemed has copy, drop {
    //     collection_id: ID,
    //     tokenized_collection_id: ID,
    //     token_type: vector<u8>,
    //     nft_id: ID,
    //     tokens_redeemed: u64,
    //     redeemer: address,
    //     timestamp: u64
    // }
    
    /// Emitted when token ratio is updated
    public struct TokenRatioUpdated has copy, drop {
        collection_id: ID,
        tokenized_collection_id: ID,
        token_type: vector<u8>,
        old_ratio: u64,
        new_ratio: u64,
        updater: address,
        timestamp: u64
    }

    // ===== Module Initialization =====
    
    fun init(witness: TOKENIZER, ctx: &mut TxContext) {
        // Create publisher capability for the module (only needed for upgrades)
        let publisher = package::claim(witness, ctx);
        let tokenizer_publisher = TokenizerPublisher {
            id: object::new(ctx)
        };
        
        // Create token registry
        let registry = TokenRegistry {
            id: object::new(ctx),
            collections: table::new(ctx),
            collection_counts: table::new(ctx),
            total_backed_tokens: table::new(ctx)
        };
        
        // Share registry
        transfer::share_object(registry);
        
        // Transfer publisher capability to deployer
        transfer::public_transfer(tokenizer_publisher, tx_context::sender(ctx));
        transfer::public_transfer(publisher, tx_context::sender(ctx));
    }
    
    // ===== Core Functions =====
    
    /// Create a new token for a collection
    /// Any collection creator can call this to create a token for their collection
    public entry fun create_token_for_collection<T: drop>(
        witness: T,
        collection_cap: &CollectionCap,
        name: vector<u8>,
        symbol: vector<u8>,
        description: vector<u8>,
        icon_url_bytes: vector<u8>,
        decimals: u8,
        tokens_per_nft: u64,
        registry: &mut TokenRegistry,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify the caller is the collection creator
        let sender = tx_context::sender(ctx);
        let collection_creator = ART20::get_collection_creator(collection_cap);
        assert!(sender == collection_creator, E_NOT_CREATOR);
        
        // Get collection info
        let collection_id = ART20::get_collection_cap_id(collection_cap);
        let initial_nft_mint = ART20::get_collection_current_supply(collection_cap);
        
        // Validate inputs
        assert!(decimals <= 9, E_INVALID_DECIMALS);
        assert!(initial_nft_mint > 0, E_INVALID_MINT_AMOUNT);
        assert!(tokens_per_nft > 0, E_INVALID_TOKEN_RATIO);
        
        // Calculate max supply and initial supply
        let max_supply = DEFAULT_MAX_SUPPLY;
        let initial_supply = safe_mul(initial_nft_mint, tokens_per_nft);
        
        // Convert bytes to strings
        let name_str = string::utf8(name);
        let symbol_str = string::utf8(symbol);
        let description_str = string::utf8(description);
        let icon_url = url::new_unsafe_from_bytes(icon_url_bytes);
        
        // Create the currency using the provided witness
        let (mut treasury_cap, metadata) = coin::create_currency(
            witness,
            decimals,
            symbol, 
            name,
            description, 
            option::some(icon_url), 
            ctx
        );
        
        // Create initial supply based on existing NFTs
        let initial_coins = coin::mint(&mut treasury_cap, initial_supply, ctx);
        
        // Create token info record
        let token_info = TokenInfo {
            id: object::new(ctx),
            name: name_str,
            symbol: symbol_str,
            description: description_str,
            icon_url,
            decimals,
            max_supply,
            creator: sender
        };
        
        // Get token type bytes
        let token_type_bytes = get_token_type_bytes<T>();
        
        // Initialize collection table for this token type if it doesn't exist yet
        if (!table::contains(&registry.collections, token_type_bytes)) {
            table::add(
                &mut registry.collections,
                token_type_bytes,
                table::new(ctx)
            );
            table::add(&mut registry.collection_counts, token_type_bytes, 0);
            table::add(&mut registry.total_backed_tokens, token_type_bytes, 0);
        };
        
        // Get the collection table for this token type
        let collection_table = table::borrow_mut(&mut registry.collections, token_type_bytes);
        
        // Check collection is not already tokenized with this token type
        assert!(!table::contains(collection_table, collection_id), E_COLLECTION_ALREADY_REGISTERED);
        
        // Create tokenized collection record
        let tokenized_collection = TokenizedCollection<T> {
            id: object::new(ctx),
            collection_id,
            token_info_id: object::uid_to_inner(&token_info.id),
            tokens_per_nft,
            total_nfts: initial_nft_mint,
            total_tokens: initial_supply,
            creator: sender,
            is_active: true,
            creation_time: clock::timestamp_ms(clock)
        };
        
        // Register tokenized collection
        let tokenized_collection_id = object::uid_to_inner(&tokenized_collection.id);
        table::add(
            collection_table, 
            collection_id, 
            tokenized_collection_id
        );
        
        // Update registry stats
        let collection_count = table::borrow_mut(&mut registry.collection_counts, token_type_bytes);
        *collection_count = *collection_count + 1;
        
        let total_backed = table::borrow_mut(&mut registry.total_backed_tokens, token_type_bytes);
        *total_backed = *total_backed + initial_supply;
        
        // Emit events
        event::emit(TokenCreated {
            token_info_id: object::uid_to_inner(&token_info.id),
            name: name_str,
            symbol: symbol_str,
            decimals,
            max_supply,
            creator: sender,
            timestamp: clock::timestamp_ms(clock)
        });
        
        event::emit(TokenizedCollectionCreated {
            collection_id,
            tokenized_collection_id,
            token_type: token_type_bytes,
            tokens_per_nft,
            initial_nft_mint,
            total_tokens: initial_supply,
            creator: sender,
            timestamp: clock::timestamp_ms(clock)
        });
        
        // Transfer objects to creator
        transfer::public_transfer(treasury_cap, sender);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(initial_coins, sender);
        transfer::share_object(token_info);
        transfer::share_object(tokenized_collection);
    }
    
    /// Mint additional NFTs and tokens for an existing tokenized collection
    public entry fun mint_additional<T>(
        registry: &mut TokenRegistry,
        tokenized_collection: &mut TokenizedCollection<T>,
        collection_cap: &mut CollectionCap,
        treasury_cap: &mut TreasuryCap<T>,
        amount: u64,
        counter: &mut TokenIdCounter,
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
        
        // Validate parameters
        assert!(amount > 0, E_INVALID_MINT_AMOUNT);
        
        // Get token type
        let token_type_bytes = get_token_type_bytes<T>();
        
        // Calculate tokens to mint
        let tokens_to_mint = safe_mul(amount, tokenized_collection.tokens_per_nft);
        
        // Check if total supply would exceed maximum
        let current_total = *table::borrow(&registry.total_backed_tokens, token_type_bytes);
        assert!(current_total + tokens_to_mint <= DEFAULT_MAX_SUPPLY, E_MAX_SUPPLY_EXCEEDED);
        
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
        
        // Mint corresponding tokens
        let minted_tokens = coin::mint(treasury_cap, tokens_to_mint, ctx);
        
        // Update tokenized collection record
        tokenized_collection.total_nfts = tokenized_collection.total_nfts + amount;
        tokenized_collection.total_tokens = tokenized_collection.total_tokens + tokens_to_mint;
        
        // Update registry stats
        let total_backed = table::borrow_mut(&mut registry.total_backed_tokens, token_type_bytes);
        *total_backed = *total_backed + tokens_to_mint;
        
        // Emit event
        event::emit(TokenizedCollectionExtended {
            collection_id: tokenized_collection.collection_id,
            tokenized_collection_id: object::uid_to_inner(&tokenized_collection.id),
            token_type: token_type_bytes,
            additional_nfts: amount,
            additional_tokens: tokens_to_mint,
            new_total_nfts: tokenized_collection.total_nfts,
            new_total_tokens: tokenized_collection.total_tokens,
            timestamp: clock::timestamp_ms(clock)
        });
        
        // Transfer tokens to creator
        transfer::public_transfer(minted_tokens, sender);
    }
    
    /// Freeze minting for a tokenized collection
    public entry fun freeze_minting<T>(
        tokenized_collection: &mut TokenizedCollection<T>,
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
            token_type: get_token_type_bytes<T>(),
            total_nfts: tokenized_collection.total_nfts,
            total_tokens: tokenized_collection.total_tokens,
            timestamp: clock::timestamp_ms(clock)
        });
    }
    
    // Redeem tokens for an ART20 NFT
    // public entry fun redeem_tokens_for_nft<T>(
    //     registry: &mut TokenRegistry,
    //     tokenized_collection: &mut TokenizedCollection<T>,
    //     collection_cap: &CollectionCap,
    //     treasury_cap: &mut TreasuryCap<T>,
    //     mut payment: Coin<T>,
    //     nft: NFT,
    //     clock: &Clock,
    //     ctx: &mut TxContext
    // ) {
    //     let sender = tx_context::sender(ctx);
        
    //     // Verify collection matches
    //     assert!(tokenized_collection.collection_id == ART20::get_collection_cap_id(collection_cap), E_COLLECTION_MISMATCH);
    //     assert!(tokenized_collection.collection_id == ART20::get_nft_collection_id(&nft), E_COLLECTION_MISMATCH);
        
    //     // Check denial list
    //     assert!(!ART20::is_denied(collection_cap, sender), E_ADDRESS_DENIED);
        
    //     // Get NFT ID
    //     let nft_id = ART20::get_nft_id(&nft);
        
    //     // Calculate required tokens
    //     let required_tokens = tokenized_collection.tokens_per_nft;
        
    //     // Verify payment is sufficient
    //     assert!(coin::value(&payment) >= required_tokens, E_INSUFFICIENT_TOKENS);
        
    //     // Process payment
    //     if (coin::value(&payment) > required_tokens) {
    //         // Calculate change amount
    //         let change_amount = coin::value(&payment) - required_tokens;
    //         // Return change
    //         let change = coin::split(&mut payment, change_amount, ctx);
    //         transfer::public_transfer(change, sender);
    //     };
        
    //     // Burn the exact amount
    //     coin::burn(treasury_cap, payment);
        
    //     // Update tokenized collection record
    //     tokenized_collection.total_nfts = tokenized_collection.total_nfts - 1;
    //     tokenized_collection.total_tokens = tokenized_collection.total_tokens - required_tokens;
        
    //     // Update registry stats
    //     let token_type_bytes = get_token_type_bytes<T>();
    //     let total_backed = table::borrow_mut(&mut registry.total_backed_tokens, token_type_bytes);
    //     *total_backed = *total_backed - required_tokens;
        
    //     // Emit event
    //     event::emit(TokensRedeemed {
    //         collection_id: tokenized_collection.collection_id,
    //         tokenized_collection_id: object::uid_to_inner(&tokenized_collection.id),
    //         token_type: token_type_bytes,
    //         nft_id,
    //         tokens_redeemed: required_tokens,
    //         redeemer: sender,
    //         timestamp: clock::timestamp_ms(clock)
    //     });
        
    //     // Transfer NFT to redeemer
    //     transfer::public_transfer(nft, sender);
    // }
    
    /// Update the token ratio for a tokenized collection (only affects future mints)
    public entry fun update_token_ratio<T>(
        tokenized_collection: &mut TokenizedCollection<T>,
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
            token_type: get_token_type_bytes<T>(),
            old_ratio,
            new_ratio,
            updater: sender,
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
    
    /// Get bytes representing a token type (for storage in tables)
    fun get_token_type_bytes<T>(): vector<u8> {
        let type_name = std::type_name::get<T>();
        std::ascii::into_bytes(std::type_name::into_string(type_name))
    }
    
    // ===== View Functions =====
    
    /// Get basic information about a token
    public fun get_token_info(token_info: &TokenInfo): (String, String, String, Url, u8, u64, address) {
        (
            token_info.name,
            token_info.symbol,
            token_info.description,
            token_info.icon_url,
            token_info.decimals,
            token_info.max_supply,
            token_info.creator
        )
    }
    
    /// Get basic information about a tokenized collection
    public fun get_collection_info<T>(tokenized_collection: &TokenizedCollection<T>): (ID, ID, u64, u64, u64, address, bool, u64) {
        (
            tokenized_collection.collection_id,
            tokenized_collection.token_info_id,
            tokenized_collection.tokens_per_nft,
            tokenized_collection.total_nfts,
            tokenized_collection.total_tokens,
            tokenized_collection.creator,
            tokenized_collection.is_active,
            tokenized_collection.creation_time
        )
    }
    
    /// Get registry statistics for a specific token type
    public fun get_registry_stats<T>(registry: &TokenRegistry): (u64, u64) {
        let token_type_bytes = get_token_type_bytes<T>();
        if (table::contains(&registry.collection_counts, token_type_bytes) && 
            table::contains(&registry.total_backed_tokens, token_type_bytes)) {
            (
                *table::borrow(&registry.collection_counts, token_type_bytes),
                *table::borrow(&registry.total_backed_tokens, token_type_bytes)
            )
        } else {
            (0, 0)
        }
    }
    
    /// Check if a collection is registered with a specific token
    public fun is_collection_registered<T>(registry: &TokenRegistry, collection_id: ID): bool {
        let token_type_bytes = get_token_type_bytes<T>();
        if (!table::contains(&registry.collections, token_type_bytes)) {
            return false
        };
        let collection_table = table::borrow(&registry.collections, token_type_bytes);
        table::contains(collection_table, collection_id)
    }
    
    /// Get tokenized collection ID for a collection with a specific token
    public fun get_tokenized_collection_id<T>(registry: &TokenRegistry, collection_id: ID): ID {
        let token_type_bytes = get_token_type_bytes<T>();
        assert!(table::contains(&registry.collections, token_type_bytes), E_COLLECTION_NOT_REGISTERED);
        let collection_table = table::borrow(&registry.collections, token_type_bytes);
        assert!(table::contains(collection_table, collection_id), E_COLLECTION_NOT_REGISTERED);
        *table::borrow(collection_table, collection_id)
    }
    
    /// Get token/NFT ratio for a collection
    public fun get_tokens_per_nft<T>(tokenized_collection: &TokenizedCollection<T>): u64 {
        tokenized_collection.tokens_per_nft
    }
    
    /// Check if a collection is active
    public fun is_collection_active<T>(tokenized_collection: &TokenizedCollection<T>): bool {
        tokenized_collection.is_active
    }
    
    /// Calculate how many tokens are needed to redeem a specific number of NFTs
    public fun calculate_redemption_cost<T>(tokenized_collection: &TokenizedCollection<T>, nft_count: u64): u64 {
        safe_mul(nft_count, tokenized_collection.tokens_per_nft)
    }
    
    /// Calculate how many NFTs can be redeemed with a specific token amount
    public fun calculate_nfts_redeemable<T>(tokenized_collection: &TokenizedCollection<T>, token_amount: u64): u64 {
        token_amount / tokenized_collection.tokens_per_nft
    }
}