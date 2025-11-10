//! PostgreSQL Provider Stress Tests for Duroxide
//!
//! This library provides PostgreSQL-specific stress test implementations for Duroxide,
//! using the provider stress test infrastructure from the main crate.
//!
//! # Quick Start
//!
//! Run the stress test binary:
//!
//! ```bash
//! cargo run --release --package duroxide-pg-stress --bin pg-stress [DURATION]
//! ```

use duroxide::provider_stress_tests::parallel_orchestrations::{
    run_parallel_orchestrations_test_with_config, ProviderStressFactory,
};
use duroxide::provider_stress_tests::StressTestConfig;
use duroxide::providers::Provider;
use duroxide_pg::PostgresProvider;
use std::sync::Arc;
use tracing::info;

// Re-export the stress test infrastructure for convenience
pub use duroxide::provider_stress_tests::{StressTestConfig as Config, StressTestResult};

/// Factory for creating PostgreSQL providers for stress testing
pub struct PostgresStressFactory {
    database_url: String,
    use_unique_schemas: bool,
}

impl PostgresStressFactory {
    pub fn new(database_url: String) -> Self {
        Self {
            database_url,
            use_unique_schemas: true,
        }
    }

    #[allow(dead_code)]
    pub fn with_shared_schema(mut self) -> Self {
        self.use_unique_schemas = false;
        self
    }
}

#[async_trait::async_trait]
impl ProviderStressFactory for PostgresStressFactory {
    async fn create_provider(&self) -> Arc<dyn Provider> {
        let schema_name = if self.use_unique_schemas {
            let guid = uuid::Uuid::new_v4().to_string();
            let suffix = &guid[guid.len() - 8..];
            format!("stress_test_{}", suffix)
        } else {
            "stress_test_shared".to_string()
        };

        info!("Creating PostgreSQL provider with schema: {}", schema_name);

        Arc::new(
            PostgresProvider::new_with_schema_and_timeout(
                &self.database_url,
                Some(&schema_name),
                30_000, // 30 second lock timeout
            )
            .await
            .expect("Failed to create PostgreSQL provider for stress test"),
        )
    }
}

/// Run the parallel orchestrations stress test suite for PostgreSQL
pub async fn run_test_suite(
    database_url: String,
    duration_secs: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    info!("=== Duroxide PostgreSQL Stress Test Suite ===");
    info!("Database: {}", mask_password(&database_url));
    info!("Duration: {} seconds per test", duration_secs);

    let concurrency_combos = vec![(1, 1), (2, 2), (4, 4)];
    let mut results = Vec::new();

    let factory = PostgresStressFactory::new(database_url);

    for (orch_conc, worker_conc) in &concurrency_combos {
        let config = StressTestConfig {
            max_concurrent: 20,
            duration_secs,
            tasks_per_instance: 5,
            activity_delay_ms: 10,
            orch_concurrency: *orch_conc,
            worker_concurrency: *worker_conc,
        };

        info!(
            "\n--- Running PostgreSQL stress test (orch={}, worker={}) ---",
            orch_conc, worker_conc
        );

        let result = run_parallel_orchestrations_test_with_config(&factory, config).await?;

        info!(
            "Completed: {}, Failed: {}, Success Rate: {:.2}%",
            result.completed,
            result.failed,
            result.success_rate()
        );
        info!(
            "Throughput: {:.2} orch/sec, {:.2} activities/sec",
            result.orch_throughput, result.activity_throughput
        );
        info!("Average latency: {:.2}ms", result.avg_latency_ms);

        results.push((
            "PostgreSQL".to_string(),
            format!("{}:{}", orch_conc, worker_conc),
            result,
        ));
    }

    // Print comparison table
    info!("\n=== Stress Test Results Summary ===\n");
    duroxide::provider_stress_tests::print_comparison_table(&results);

    // Validate all tests passed
    for (provider, config, result) in &results {
        if result.success_rate() < 100.0 {
            return Err(format!(
                "Stress test {} {} had failures: {:.2}% success rate",
                provider,
                config,
                result.success_rate()
            )
            .into());
        }
    }

    info!("\n✅ All stress tests passed!");
    Ok(())
}

fn mask_password(url: &str) -> String {
    if let Some(at_pos) = url.find('@') {
        if let Some(colon_pos) = url[..at_pos].rfind(':') {
            let mut masked = url.to_string();
            masked.replace_range(colon_pos + 1..at_pos, "***");
            return masked;
        }
    }
    url.to_string()
}

