module suistream::subscription {
    // Imports
    use sui::transfer;
    use sui::coin::{self, Coin};
    use sui::object::{self, UID, ID};
    use sui::tx_context::{self, TxContext, sender};
    use sui::table::{self, Table};
    use sui::clock::{Clock, timestamp_ms};
    use sui::event;

    use std::option::{self, Option, none, some};
    use std::string::{String};
    use std::vector;

    // Errors
    const ERROR_INVALID_CAP: u64 = 0;
    const ERROR_INSUFFICIENT_FUNDS: u64 = 1;
    const ERROR_WRONG_CREATOR: u64 = 2;
    const ERROR_SUBSCRIPTION_NOT_FOUND: u64 = 3;
    const ERROR_SUBSCRIPTION_EXPIRED: u64 = 4;

    // Struct definitions
    struct SubscriptionCreator has key, store {
        id: UID,
        creator: address,
        subscriptions: Table<String, Subscription>
    }

    struct SubscriptionCreatorCap has key, store {
        id: UID,
        creator_id: ID
    }

    struct Subscription has key, store {
        id: UID,
        name: String,
        description: String,
        price: u64,
        duration: u64, // in milliseconds
        subscribers: Table<address, Subscriber>,
        content: vector<u8>
    }

    struct Subscriber has store {
        id: UID,
        subscriber: address,
        subscription_id: ID,
        expiration: u64
    }

    // Events
    struct SubscriptionCreatedEvent has copy, drop {
        name: String,
        description: String,
        price: u64,
        duration: u64,
        creator: address
    }

    struct SubscriptionPurchasedEvent has copy, drop {
        subscriber: address,
        subscription_id: ID,
        expiration: u64
    }

    struct SubscriptionCancelledEvent has copy, drop {
        subscriber: address,
        subscription_id: ID
    }

    // Public - Entry functions

    // Create a new subscription creator
    public entry fun create_creator(ctx: &mut TxContext) {
        let creator_id = object::new(ctx);
        transfer::share_object(SubscriptionCreator {
            id: creator_id,
            creator: sender(ctx),
            subscriptions: table::new(ctx)
        });

        transfer::transfer(SubscriptionCreatorCap {
            id: object::new(ctx),
            creator_id: object::uid_to_inner(&creator_id)
        }, sender(ctx));
    }

    // Create a new subscription
    public entry fun create_subscription(
        cap: &SubscriptionCreatorCap,
        creator: &mut SubscriptionCreator,
        name: String,
        description: String,
        price: u64,
        duration: u64,
        content: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(cap.creator_id == object::id(creator), ERROR_INVALID_CAP);
        assert!(creator.creator == sender(ctx), ERROR_WRONG_CREATOR);

        let subscription = Subscription {
            id: object::new(ctx),
            name: name.clone(),
            description,
            price,
            duration,
            subscribers: table::new(ctx),
            content
        };

        table::add(&mut creator.subscriptions, name, subscription);

        event::emit(SubscriptionCreatedEvent {
            name,
            description,
            price,
            duration,
            creator: sender(ctx)
        });
    }

    // Purchase a subscription
    public entry fun purchase_subscription(
        cap: &SubscriptionCreatorCap,
        creator: &mut SubscriptionCreator,
        subscription_name: String,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(cap.creator_id == object::id(creator), ERROR_INVALID_CAP);

        let subscription = table::borrow_mut(&mut creator.subscriptions, subscription_name.clone());
        assert!(option::is_some(&subscription), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscription_mut = option::borrow_mut(&subscription);
        assert!(coin::value(&payment) == subscription_mut.price, ERROR_INSUFFICIENT_FUNDS);

        let expiration = timestamp_ms(&Clock {}) + subscription_mut.duration;
        let subscriber = Subscriber {
            id: object::new(ctx),
            subscriber: sender(ctx),
            subscription_id: object::id(subscription_mut),
            expiration
        };

        table::add(&mut subscription_mut.subscribers, sender(ctx), subscriber);
        coin::destroy_zero(payment);

        event::emit(SubscriptionPurchasedEvent {
            subscriber: sender(ctx),
            subscription_id: object::id(subscription_mut),
            expiration
        });
    }

    // Access subscription content
    public fun access_content(
        cap: &SubscriptionCreatorCap,
        creator: &SubscriptionCreator,
        subscription_name: String,
        ctx: &mut TxContext
    ): vector<u8> {
        assert!(cap.creator_id == object::id(creator), ERROR_INVALID_CAP);

        let subscription = table::borrow(&creator.subscriptions, subscription_name.clone());
        assert!(option::is_some(&subscription), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscription_obj = option::borrow(&subscription);
        let subscriber = table::borrow(&subscription_obj.subscribers, sender(ctx));
        assert!(option::is_some(&subscriber), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscriber_obj = option::borrow(&subscriber);
        assert!(timestamp_ms(&Clock {}) < subscriber_obj.expiration, ERROR_SUBSCRIPTION_EXPIRED);

        subscription_obj.content.clone()
    }

    // Cancel a subscription
    public entry fun cancel_subscription(
        cap: &SubscriptionCreatorCap,
        creator: &mut SubscriptionCreator,
        subscription_name: String,
        ctx: &mut TxContext
    ) {
        assert!(cap.creator_id == object::id(creator), ERROR_INVALID_CAP);

        let subscription = table::borrow_mut(&mut creator.subscriptions, subscription_name.clone());
        assert!(option::is_some(&subscription), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscription_mut = option::borrow_mut(&subscription);
        let subscriber = table::remove(&mut subscription_mut.subscribers, sender(ctx));
        assert!(option::is_some(&subscriber), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscriber_obj = option::borrow(&subscriber);
        assert!(timestamp_ms(&Clock {}) < subscriber_obj.expiration, ERROR_SUBSCRIPTION_EXPIRED);

        event::emit(SubscriptionCancelledEvent {
            subscriber: sender(ctx),
            subscription_id: object::id(subscription_mut)
        });
    }
}
