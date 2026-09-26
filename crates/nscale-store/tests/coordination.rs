//! Run against an isolated Redis: NSCALE_TEST_REDIS_URL=redis://... cargo nextest
//! run -p nscale-store --test coordination --run-ignored only
use nscale_core::{
    job::ScaleUnit,
    lease::{Lease, unique_token},
    traits::ActivityStore,
};
use nscale_store::activity::RedisActivityStore;
use std::{sync::Arc, time::Duration};

async fn store() -> Arc<RedisActivityStore> {
    Arc::new(
        RedisActivityStore::new(
            &std::env::var("NSCALE_TEST_REDIS_URL").expect("isolated test Redis required"),
        )
        .await
        .unwrap(),
    )
}

#[tokio::test]
#[ignore = "requires isolated Redis"]
async fn service_identity_wins_over_job_alias_without_changing_admin_lookup() {
    use fred::prelude::*;
    use nscale_core::job::JobRegistration;
    use nscale_store::registry::JobRegistry;
    let store = store().await;
    let registry = JobRegistry::new(store.client().clone());
    let name = unique_token();
    let first = JobRegistration {
        job_id: name.clone().into(),
        service_name: name.clone().into(),
        nomad_group: "web".into(),
        scale_unit: Some(format!("{name}/web")),
        autoscaling: None,
        traefik_routers: vec![],
    };
    registry.register(&first).await.unwrap();
    let _: i64 = store
        .client()
        .hdel("nscale:jobs:services", &name)
        .await
        .unwrap();
    assert_eq!(
        registry
            .get_by_service_name(&first.service_name)
            .await
            .unwrap()
            .unwrap()
            .service_name,
        first.service_name,
        "exact legacy cache entry still resolves"
    );
    registry.register(&first).await.unwrap();
    let second = JobRegistration {
        service_name: format!("{name}-metrics").into(),
        nomad_group: "monitoring".into(),
        scale_unit: Some(format!("{name}/monitoring")),
        ..first.clone()
    };
    registry.register(&second).await.unwrap();
    let proxy = registry
        .get_by_service_name(&first.service_name)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(proxy.service_name, first.service_name);
    assert_eq!(proxy.nomad_group, "web");
    assert_eq!(
        registry
            .get(&first.job_id)
            .await
            .unwrap()
            .unwrap()
            .service_name,
        second.service_name,
        "admin job alias remains compatible"
    );
    let _: i64 = store
        .client()
        .hdel("nscale:jobs:services", &name)
        .await
        .unwrap();
    assert!(
        registry
            .get_by_service_name(&first.service_name)
            .await
            .unwrap()
            .is_none(),
        "a sibling in the job cache must not impersonate a missing service"
    );
    registry.deregister(&first.job_id).await.unwrap();
}

#[tokio::test]
#[ignore = "requires isolated Redis"]
async fn expired_owner_cannot_release_or_renew_successor_lease() {
    let first = store().await;
    let second = store().await;
    let key = unique_token();
    assert!(
        first
            .acquire_lease(&key, "old", Duration::from_millis(30))
            .await
            .unwrap()
    );
    tokio::time::sleep(Duration::from_millis(60)).await;
    assert!(
        second
            .acquire_lease(&key, "new", Duration::from_secs(10))
            .await
            .unwrap()
    );
    assert!(
        !first
            .renew_lease(&key, "old", Duration::from_secs(10))
            .await
            .unwrap()
    );
    first.release_lease(&key, "old").await.unwrap();
    assert!(
        !first
            .acquire_lease(&key, "third", Duration::from_secs(10))
            .await
            .unwrap()
    );
    second.release_lease(&key, "new").await.unwrap();
}

#[tokio::test]
#[ignore = "requires isolated Redis"]
async fn requests_are_visible_across_replicas_and_expire_after_crash() {
    let first = store().await;
    let second = store().await;
    let unit = ScaleUnit(unique_token());
    first
        .refresh_request(&unit, "one", Duration::from_millis(50))
        .await
        .unwrap();
    first
        .refresh_request(&unit, "two", Duration::from_secs(10))
        .await
        .unwrap();
    assert_eq!(second.active_requests(&unit).await.unwrap(), 2);
    tokio::time::sleep(Duration::from_millis(90)).await;
    assert_eq!(second.active_requests(&unit).await.unwrap(), 1);
    first.finish_request(&unit, "two").await.unwrap();
    assert_eq!(second.active_requests(&unit).await.unwrap(), 0);
    first.remove_activity(&unit).await.unwrap();
}

#[tokio::test]
#[ignore = "requires isolated Redis; exercises lease renewal for 35 seconds"]
async fn long_sweep_renews_ownership() {
    let first = store().await;
    let second = store().await;
    let key = unique_token();
    let lease = Lease::acquire(first, key.clone()).await.unwrap().unwrap();
    lease
        .run(async {
            tokio::time::sleep(Duration::from_secs(35)).await;
            assert!(
                !second
                    .acquire_lease(&key, "competitor", Duration::from_secs(10))
                    .await
                    .unwrap()
            );
            Ok(())
        })
        .await
        .unwrap();
}

#[tokio::test]
#[ignore = "requires isolated Redis; exercises lease-loss cancellation"]
async fn lease_loss_cancels_work_before_further_mutations() {
    use fred::prelude::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    let first = store().await;
    let second = store().await;
    let key = unique_token();
    let lease = Lease::acquire(first.clone(), key.clone())
        .await
        .unwrap()
        .unwrap();
    let _: i64 = first
        .client()
        .del(format!("nscale:lock:{key}"))
        .await
        .unwrap();
    assert!(
        second
            .acquire_lease(&key, "successor", Duration::from_secs(30))
            .await
            .unwrap()
    );
    let mutated = AtomicBool::new(false);
    let result = lease
        .run(async {
            tokio::time::sleep(Duration::from_secs(20)).await;
            mutated.store(true, Ordering::SeqCst);
            Ok(())
        })
        .await;
    assert!(result.is_err());
    assert!(!mutated.load(Ordering::SeqCst));
    second.release_lease(&key, "successor").await.unwrap();
}

#[tokio::test]
#[ignore = "requires isolated Redis"]
async fn completed_work_releases_lease_before_returning() {
    let store = store().await;
    let key = unique_token();
    for fail in [false, true] {
        let lease = Lease::acquire(store.clone(), key.clone())
            .await
            .unwrap()
            .unwrap();
        let result = lease
            .run(async {
                if fail {
                    Err(nscale_core::error::NscaleError::Store("work failed".into()))
                } else {
                    Ok(())
                }
            })
            .await;
        assert_eq!(result.is_err(), fail);
        assert!(
            store
                .acquire_lease(&key, "next", Duration::from_secs(10))
                .await
                .unwrap()
        );
        store.release_lease(&key, "next").await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires isolated Redis"]
async fn cancelled_work_releases_lease_via_drop() {
    let store = store().await;
    let key = unique_token();
    let lease = Lease::acquire(store.clone(), key.clone())
        .await
        .unwrap()
        .unwrap();
    let task = tokio::spawn(lease.run(std::future::pending::<nscale_core::error::Result<()>>()));
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if store
                .acquire_lease(&key, "next", Duration::from_secs(10))
                .await
                .unwrap()
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    store.release_lease(&key, "next").await.unwrap();
}
