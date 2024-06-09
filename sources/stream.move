module suistream::subscription {
    // Imports
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{TxContext, sender};
    use sui::table::{Self, Table};
    use sui::clock::{Clock, timestamp_ms};
    use sui::event;

    use std::option::{Option, none, some};
    use std::string::{String};
    use std::vector;

    // Errors
    const ERROR_INVALID_CAP: u64 = 0;
    const ERROR_INSUFFICIENT_FUNDS: u64 = 1;
    const ERROR_WRONG_CREATOR: u64 = 2;
    const ERROR_SUBSCRIPTION_NOT_FOUND: u64 = 3;
    const ERROR_SUBSCRIPTION_EXPIRED: u64 = 4;
    const ERROR_SUBSCRIPTION_EXISTS: u64 = 5; // New error for existing subscription name
    const ERROR_INVALID_DURATION: u64 = 6; // New error for invalid duration

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

    // Helper functions

    // Get a subscriber object based on subscription name and sender's address
    fun get_subscriber(subscription: &Subscription, ctx: &mut TxContext): &Subscriber {
        let subscriber = table::borrow(&subscription.subscribers, sender(ctx));
        assert!(subscriber != none(), ERROR_SUBSCRIPTION_NOT_FOUND);
        subscriber.borrow()
    }

    // Public - Entry functions

    // Create a new subscription creator
    public entry fun create_creator(ctx: &mut TxContext) {
        transfer::share_object(SubscriptionCreator {
            id: object::new(ctx),
            creator: sender(ctx),
            subscriptions: table::new(ctx)
        });

        transfer::transfer(SubscriptionCreatorCap {
            id: object::new(ctx),
            creator_id: object::uid_to_inner(&object::new(ctx))
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
        assert!(table::borrow(&creator.subscriptions, name) == none(), ERROR_SUBSCRIPTION_EXISTS); // Check if subscription name already exists
        assert!(duration > 0 && duration <= 31536000000, ERROR_INVALID_DURATION); // Limit duration to 1 year

        let subscription = Subscription {
            id: object::new(ctx),
            name: name,
            description: description,
            price: price,
            duration: duration,
            subscribers: table::new(ctx),
            content: content
        };

        table::add(&mut creator.subscriptions, name, subscription);

        event::emit(SubscriptionCreatedEvent {
            name: name,
            description: description,
            price: price,
            duration: duration,
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

        let subscription = table::borrow_mut(&mut creator.subscriptions, subscription_name);
        assert!(subscription != none(), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscription_mut = subscription.borrow_mut();
        assert!(coin::value(&payment) == subscription_mut.price, ERROR_INSUFFICIENT_FUNDS);

        let expiration = timestamp_ms(&Clock {}) + subscription_mut.duration;
        let subscriber = Subscriber {
            id: object::new(ctx),
            subscriber: sender(ctx),
            subscription_id: object::id(subscription_mut),
            expiration: expiration
        };

        table::add(&mut subscription_mut.subscribers, sender(ctx), subscriber);
        coin::destroy_zero(payment);

        event::emit(SubscriptionPurchasedEvent {
            subscriber: sender(ctx),
            subscription_id: object::id(subscription_mut),
            expiration: expiration
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

        let subscription = table::borrow(&creator.subscriptions, subscription_name);
        assert!(subscription != none(), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscription_obj = subscription.borrow();
        let subscriber = get_subscriber(subscription_obj, ctx);
        assert!(timestamp_ms(&Clock {}) < subscriber.expiration, ERROR_SUBSCRIPTION_EXPIRED);

        subscription_obj.content
    }

    // Update subscription content
    public entry fun update_subscription_content(
        cap: &SubscriptionCreatorCap,
        creator: &mut SubscriptionCreator,
        subscription_name: String,
        new_content: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(cap.creator_id == object::id(creator), ERROR_INVALID_CAP);
        assert!(creator.creator == sender(ctx), ERROR_WRONG_CREATOR);

        let subscription = table::borrow_mut(&mut creator.subscriptions, subscription_name);
        assert!(subscription != none(), ERROR_SUBSCRIPTION_NOT_FOUND);

        let subscription_mut = subscription.borrow_mut();
        subscription_mut.content = new_content;
    }

    // Cancel subscription
    public entry fun cancel_subscription(
        cap: &SubscriptionCreatorCap,
        creator: &mut SubscriptionCreator,
        subscription_name: String,
        ctx: &mut TxContext
    ) {
        assert!(cap.creator_id == object::id(creator), ERROR_INVALID_CAP);
        assert!(creator.creator == sender(ctx), ERROR_WRONG_CREATOR);

        table::remove(&mut creator.subscriptions, subscription_name);
    }

    // Get all subscriptions
    public fun get_all_subscriptions(creator: &SubscriptionCreator): vector<Subscription> {
        let subscriptions = vector::empty<Subscription>();
        let subscriptions_table = table::borrow(&creator.subscriptions);
        table::for_each(&subscriptions_table, |_, subscription| {
            vector::push_back(&mut subscriptions, *subscription);
        });
        subscriptions
    }
