# PostgreSQL Provider Stress Test Implementation Plan

## Overview

This document outlines the plan for implementing stress tests for the `duroxide-pg` PostgreSQL provider using the stress test framework from the main `duroxide` crate (commit `8e0952e`).

---

## Background: Duroxide Stress Test Framework

The `duroxide` crate provides a reusable stress test infrastructure (enabled via `provider-test` feature) that validates providers under load conditions.

### Key Components

1. **`StressTestConfig`** - Configuration for test parameters
   - `max_concurrent`: Maximum concurrent orchestrations
   - `duration_secs`: Test duration
   - `tasks_per_instance`: Fan-out degree per orchestration
   - `activity_delay_ms`: Simulated activity execution time
   - `orch_concurrency`: Number of orchestration dispatcher workers
   - `worker_concurrency`: Number of activity dispatcher workers

2. **`ProviderStressFactory`** - Trait for creating provider instances
   - Implement to provide fresh provider instances for each test run

3. **`StressTestResult`** - Metrics from test execution
   - Success rate, throughput, latency
   - Failure categorization (infrastructure/configuration/application)

4. **Test Scenarios**
   - `parallel_orchestrations`: Fan-out/fan-in pattern with concurrent instances
   - Future: timer-based, long-running, sub-orchestration patterns

### Reference Implementation

The SQLite provider has a complete stress test implementation in `duroxide/sqlite-stress/`:
- `src/lib.rs`: Factory implementations and test suite runner
- `src/bin/sqlite-stress.rs`: CLI binary for running tests
- `track-results.sh`: Script for tracking results over time

---

## Implementation Plan

### Phase 1: Basic Infrastructure

#### 1.1 Create `pg-stress` Package

Create a new workspace member alongside the main provider:

```toml
# /Users/affandar/workshop/duroxide-pg/pg-stress/Cargo.toml
[package]
name = "duroxide-pg-stress"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "pg-stress"
path = "src/bin/pg-stress.rs"

[dependencies]
duroxide = { git = "https://github.com/affandar/duroxide", features = ["provider-test"] }
duroxide-pg = { path = ".." }
tokio = { version = "1", features = ["full"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
dotenvy = "0.15"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
anyhow = "1.0"
clap = { version = "4.0", features = ["derive"] }
```

Update workspace root `Cargo.toml`:

```toml
[workspace]
members = [".", "pg-stress"]
```

#### 1.2 Implement Provider Factory

```rust
// pg-stress/src/lib.rs
use duroxide::provider_stress_tests::parallel_orchestrations::ProviderStressFactory;
use duroxide::providers::Provider;
use duroxide_pg::PostgresProvider;
use std::sync::Arc;
use tracing::info;

pub use duroxide::provider_stress_tests::{StressTestConfig, StressTestResult};

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
            PostgresProvider::new_with_schema(
                &self.database_url,
                Some(&schema_name),
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
    use duroxide::provider_stress_tests::parallel_orchestrations::run_parallel_orchestrations_test_with_config;

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
            format!("PostgreSQL ({}:{})", orch_conc, worker_conc),
            result,
        ));
    }

    // Print comparison table
    info!("\n=== Stress Test Results Summary ===\n");
    duroxide::provider_stress_tests::print_comparison_table(&results);

    // Validate all tests passed
    for (name, result) in &results {
        if result.success_rate() < 100.0 {
            return Err(format!(
                "Stress test {} had failures: {:.2}% success rate",
                name,
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
```

#### 1.3 Create CLI Binary

```rust
// pg-stress/src/bin/pg-stress.rs
use clap::Parser;
use duroxide_pg_stress::run_test_suite;
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "pg-stress")]
#[command(about = "PostgreSQL provider stress tests for Duroxide", long_about = None)]
struct Args {
    /// Duration of each stress test in seconds
    #[arg(short, long, default_value = "10")]
    duration: u64,

    /// PostgreSQL connection URL (or set DATABASE_URL env var)
    #[arg(short, long, env = "DATABASE_URL")]
    database_url: String,

    /// Track results to file for comparison
    #[arg(long)]
    track: bool,

    /// Track results with cloud environment tag
    #[arg(long)]
    track_cloud: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize logging
    let env_filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_target(false)
        .init();

    // Load .env if present
    dotenvy::dotenv().ok();

    let args = Args::parse();

    // Run stress test suite
    run_test_suite(args.database_url, args.duration).await?;

    // TODO: Implement result tracking if --track or --track-cloud is set
    if args.track || args.track_cloud {
        eprintln!("Note: Result tracking not yet implemented for PostgreSQL provider");
    }

    Ok(())
}
```

---

### Phase 2: Test Configurations

#### 2.1 Local Development Configuration

For fast iteration during development:

```rust
StressTestConfig {
    max_concurrent: 10,
    duration_secs: 5,
    tasks_per_instance: 3,
    activity_delay_ms: 5,
    orch_concurrency: 2,
    worker_concurrency: 2,
}
```

**Expected performance (local Docker PostgreSQL):**
- Throughput: 5-10 orch/sec
- Success rate: 100%
- Duration: ~5 seconds

#### 2.2 CI/CD Configuration

For automated testing in CI pipelines:

```rust
StressTestConfig {
    max_concurrent: 20,
    duration_secs: 10,
    tasks_per_instance: 5,
    activity_delay_ms: 10,
    orch_concurrency: 2,
    worker_concurrency: 2,
}
```

**Expected performance (remote Azure PostgreSQL):**
- Throughput: 2-5 orch/sec (network latency)
- Success rate: 100%
- Duration: ~10 seconds

#### 2.3 Production Validation Configuration

For comprehensive validation before releases:

```rust
StressTestConfig {
    max_concurrent: 50,
    duration_secs: 60,
    tasks_per_instance: 10,
    activity_delay_ms: 10,
    orch_concurrency: 4,
    worker_concurrency: 4,
}
```

**Expected performance:**
- Throughput: 3-8 orch/sec
- Success rate: 100%
- Duration: ~60 seconds
- Total orchestrations: 180-480

---

### Phase 3: Integration Tests

#### 3.1 Add Stress Test to Test Suite

```rust
// tests/stress_tests.rs
use duroxide_pg_stress::{PostgresStressFactory, StressTestConfig};
use duroxide::provider_stress_tests::parallel_orchestrations::run_parallel_orchestrations_test_with_config;

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

#[tokio::test]
#[ignore] // Run with --ignored flag
async fn stress_test_parallel_orchestrations_light() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 10,
        duration_secs: 5,
        tasks_per_instance: 3,
        activity_delay_ms: 5,
        orch_concurrency: 2,
        worker_concurrency: 2,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    // Assert quality requirements
    assert_eq!(
        result.success_rate(),
        100.0,
        "Expected 100% success rate, got {:.2}%",
        result.success_rate()
    );
    assert!(
        result.failed_infrastructure == 0,
        "Infrastructure failures detected: {}",
        result.failed_infrastructure
    );
    assert!(
        result.orch_throughput > 1.0,
        "Throughput too low: {:.2} orch/sec",
        result.orch_throughput
    );
}

#[tokio::test]
#[ignore]
async fn stress_test_parallel_orchestrations_standard() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 20,
        duration_secs: 10,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 2,
        worker_concurrency: 2,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    assert_eq!(result.success_rate(), 100.0);
    assert_eq!(result.failed_infrastructure, 0);
}

#[tokio::test]
#[ignore]
async fn stress_test_high_concurrency() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 50,
        duration_secs: 30,
        tasks_per_instance: 10,
        activity_delay_ms: 10,
        orch_concurrency: 4,
        worker_concurrency: 4,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    assert_eq!(result.success_rate(), 100.0);
    assert_eq!(result.failed_infrastructure, 0);
    
    // Validate throughput meets minimum requirements
    assert!(
        result.orch_throughput > 2.0,
        "Throughput below minimum: {:.2} orch/sec",
        result.orch_throughput
    );
}
```

#### 3.2 Add Convenience Script

```bash
# scripts/run-pg-stress-tests.sh
#!/bin/bash
# Run PostgreSQL provider stress tests

set -e

DURATION=${1:-10}
DATABASE_URL=${DATABASE_URL:-$(grep '^DATABASE_URL=' .env | cut -d= -f2-)}

if [ -z "$DATABASE_URL" ]; then
    echo "Error: DATABASE_URL not set"
    echo "Usage: $0 [DURATION_SECS]"
    echo "Set DATABASE_URL environment variable or in .env file"
    exit 1
fi

echo "=== Running PostgreSQL Provider Stress Tests ==="
echo "Duration: ${DURATION}s per test"
echo "Database: $(echo $DATABASE_URL | sed 's/:.*@/:***@/')"
echo ""

cd pg-stress
cargo run --release --bin pg-stress -- --duration $DURATION --database-url "$DATABASE_URL"
```

---

### Phase 4: Result Tracking & Comparison

#### 4.1 Result Tracking Script

```bash
# pg-stress/track-results.sh
#!/bin/bash
# Track stress test results over time for PostgreSQL provider

set -e

DURATION=${1:-10}
RESULTS_FILE="stress-test-results.md"
CLOUD_RESULTS_FILE="stress-test-results-cloud.md"
TRACK_CLOUD=${TRACK_CLOUD:-false}

# Get git commit info
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Determine which results file to use
if [ "$TRACK_CLOUD" = "true" ]; then
    TARGET_FILE="$CLOUD_RESULTS_FILE"
    ENV_TAG="Azure PostgreSQL (remote)"
else
    TARGET_FILE="$RESULTS_FILE"
    ENV_TAG="Local PostgreSQL"
fi

echo "Running stress tests and tracking results to $TARGET_FILE..."
echo "Environment: $ENV_TAG"
echo ""

# Run stress tests and capture output
OUTPUT=$(cargo run --release --bin pg-stress -- --duration $DURATION 2>&1)

# Extract key metrics from output
SUCCESS_RATE=$(echo "$OUTPUT" | grep -oP 'Success Rate: \K[\d.]+' | head -1)
THROUGHPUT=$(echo "$OUTPUT" | grep -oP 'Throughput: \K[\d.]+' | head -1)
AVG_LATENCY=$(echo "$OUTPUT" | grep -oP 'Average latency: \K[\d.]+' | head -1)

# Append to results file
{
    echo ""
    echo "## Run: $DATE"
    echo ""
    echo "- **Commit**: \`$COMMIT\` (branch: \`$BRANCH\`)"
    echo "- **Environment**: $ENV_TAG"
    echo "- **Duration**: ${DURATION}s"
    echo ""
    echo "### Results"
    echo ""
    echo "\`\`\`"
    echo "$OUTPUT" | grep -A 50 "=== Stress Test Results Summary ==="
    echo "\`\`\`"
    echo ""
    echo "### Key Metrics"
    echo ""
    echo "- Success Rate: ${SUCCESS_RATE}%"
    echo "- Throughput: ${THROUGHPUT} orch/sec"
    echo "- Avg Latency: ${AVG_LATENCY}ms"
    echo ""
    echo "---"
} >> "$TARGET_FILE"

echo "Results appended to $TARGET_FILE"
echo ""
echo "=== Summary ==="
echo "Success Rate: ${SUCCESS_RATE}%"
echo "Throughput: ${THROUGHPUT} orch/sec"
echo "Avg Latency: ${AVG_LATENCY}ms"
```

#### 4.2 Comparison Baseline

Create initial baseline results for comparison:

```markdown
# stress-test-results.md

# PostgreSQL Provider Stress Test Results

This file tracks stress test performance over time for the PostgreSQL provider.

## Baseline (Initial Implementation)

- **Date**: 2025-11-10
- **Commit**: `e0a0ddf`
- **Environment**: Azure PostgreSQL (remote, 500 connection limit)
- **Configuration**: 
  - max_concurrent: 20
  - duration: 10s
  - tasks_per_instance: 5
  - activity_delay: 10ms

### Expected Results

| Config | Completed | Failed | Success % | Orch/sec | Activity/sec | Avg Latency |
|--------|-----------|--------|-----------|----------|--------------|-------------|
| 1:1    | TBD       | 0      | 100.0%    | TBD      | TBD          | TBD         |
| 2:2    | TBD       | 0      | 100.0%    | TBD      | TBD          | TBD         |
| 4:4    | TBD       | 0      | 100.0%    | TBD      | TBD          | TBD         |

---
```

---

### Phase 5: Advanced Stress Tests

#### 5.1 Connection Pool Stress

Test provider behavior under connection pool exhaustion:

```rust
#[tokio::test]
#[ignore]
async fn stress_test_connection_pool_limits() {
    let database_url = get_database_url();
    
    // Override pool size to small value
    std::env::set_var("DUROXIDE_PG_POOL_MAX", "5");
    
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 30, // More than pool size
        duration_secs: 10,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 4,
        worker_concurrency: 4,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    // Should still succeed despite pool pressure
    assert_eq!(result.success_rate(), 100.0);
}
```

#### 5.2 Long-Duration Stability Test

Test for memory leaks and resource exhaustion:

```rust
#[tokio::test]
#[ignore]
async fn stress_test_long_duration_stability() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 20,
        duration_secs: 300, // 5 minutes
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 2,
        worker_concurrency: 2,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    assert_eq!(result.success_rate(), 100.0);
    
    // Validate sustained throughput
    assert!(
        result.orch_throughput > 1.5,
        "Throughput degraded over time: {:.2} orch/sec",
        result.orch_throughput
    );
}
```

#### 5.3 Network Latency Simulation

Test behavior under high-latency conditions:

```rust
#[tokio::test]
#[ignore]
async fn stress_test_high_latency_network() {
    // This test should be run against remote Azure PostgreSQL
    let database_url = std::env::var("DATABASE_URL_REMOTE")
        .expect("DATABASE_URL_REMOTE must be set for latency test");
    
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 10,
        duration_secs: 20,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 2,
        worker_concurrency: 2,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    // Should still succeed despite high latency
    assert_eq!(result.success_rate(), 100.0);
    
    // Latency will be higher, but throughput should be reasonable
    assert!(
        result.orch_throughput > 0.5,
        "Throughput too low for high-latency network: {:.2} orch/sec",
        result.orch_throughput
    );
}
```

---

## Execution Strategy

### Local Development

```bash
# Quick smoke test (5 seconds)
cd pg-stress
cargo run --release --bin pg-stress -- --duration 5

# Standard test (10 seconds)
cargo run --release --bin pg-stress -- --duration 10

# Or use convenience script
cd ..
./scripts/run-pg-stress-tests.sh 10
```

### CI/CD Integration

```yaml
# .github/workflows/stress-tests.yaml
name: Stress Tests

on:
  push:
    branches: [main]
  schedule:
    - cron: '0 0 * * 0'  # Weekly on Sunday

jobs:
  stress-test-local:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: duroxide_test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432
    steps:
      - uses: actions/checkout@v3
      - uses: actions-rs/toolchain@v1
        with:
          toolchain: stable
      
      - name: Run stress tests (local)
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/duroxide_test
        run: |
          cd pg-stress
          cargo run --release --bin pg-stress -- --duration 10

  stress-test-azure:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions-rs/toolchain@v1
        with:
          toolchain: stable
      
      - name: Run stress tests (Azure)
        env:
          DATABASE_URL: ${{ secrets.AZURE_DATABASE_URL }}
        run: |
          cd pg-stress
          cargo run --release --bin pg-stress -- --duration 10 --track-cloud
      
      - name: Upload results
        uses: actions/upload-artifact@v3
        with:
          name: stress-test-results
          path: pg-stress/stress-test-results-cloud.md
```

### Manual Testing

```bash
# Test against local Docker PostgreSQL
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/duroxide_test \
  cargo run --release --package duroxide-pg-stress --bin pg-stress -- --duration 10

# Test against Azure PostgreSQL
DATABASE_URL=postgresql://affandar:War3Craft@duroxide-pg.postgres.database.azure.com:5432/postgres \
  cargo run --release --package duroxide-pg-stress --bin pg-stress -- --duration 10 --track-cloud
```

---

## Performance Expectations

### Local PostgreSQL (Docker)

Based on SQLite in-memory performance as reference:

| Metric | Expected Range | Notes |
|--------|----------------|-------|
| Success Rate | 100% | Zero tolerance for failures |
| Throughput (1:1) | 8-15 orch/sec | Single-threaded baseline |
| Throughput (2:2) | 15-30 orch/sec | Parallel processing benefit |
| Throughput (4:4) | 25-50 orch/sec | Scales with concurrency |
| Avg Latency | 50-150ms | Local network overhead |

### Remote Azure PostgreSQL

Network latency will dominate:

| Metric | Expected Range | Notes |
|--------|----------------|-------|
| Success Rate | 100% | Zero tolerance for failures |
| Throughput (1:1) | 2-5 orch/sec | Network RTT ~100-200ms |
| Throughput (2:2) | 3-8 orch/sec | Parallelism helps |
| Throughput (4:4) | 4-12 orch/sec | Diminishing returns |
| Avg Latency | 200-500ms | Network + query time |

### Comparison to SQLite

**Expected relative performance:**
- PostgreSQL (local): 70-90% of SQLite in-memory throughput
- PostgreSQL (remote): 20-40% of SQLite in-memory throughput
- Success rate: Equal (100%)

**PostgreSQL advantages over SQLite:**
- True concurrent writes (no WAL serialization)
- Better scaling with high concurrency (4+ workers)
- Production-ready for distributed deployments

---

## Validation Criteria

### Must Pass (Blocking)

1. ✅ **100% success rate** across all configurations
2. ✅ **Zero infrastructure failures** (provider bugs)
3. ✅ **Zero configuration failures** (nondeterminism, missing features)
4. ✅ **Minimum throughput**: > 1.0 orch/sec (even on remote)

### Should Pass (Warning)

1. ⚠️ **Throughput regression**: < 20% drop from previous runs
2. ⚠️ **Latency increase**: > 50% increase from previous runs
3. ⚠️ **Memory growth**: Sustained increase over long runs

### Nice to Have (Informational)

1. 📊 **Throughput improvement** over previous versions
2. 📊 **Latency reduction** with stored procedures
3. 📊 **Scaling efficiency** with increased concurrency

---

## Troubleshooting

### Common Issues

#### 1. Connection Pool Exhaustion

**Symptom:** `PoolTimedOut` errors during stress test

**Solutions:**
- Increase `DUROXIDE_PG_POOL_MAX` (default: 10)
- Reduce `max_concurrent` in test config
- Check Azure PostgreSQL connection limit

#### 2. Lock Contention

**Symptom:** High latency, low throughput, "Invalid lock token" errors

**Solutions:**
- Review `fetch_orchestration_item` stored procedure locking logic
- Check for deadlocks in PostgreSQL logs
- Verify `FOR UPDATE SKIP LOCKED` is working correctly

#### 3. Schema Cleanup Failures

**Symptom:** "Schema already exists" or cleanup errors

**Solutions:**
- Ensure unique schema names per test run (GUID-based)
- Add retry logic to schema cleanup
- Manually clean up: `DROP SCHEMA IF EXISTS stress_test_% CASCADE;`

#### 4. Timeout Waiting for Orchestrations

**Symptom:** Orchestrations don't complete within 60s timeout

**Solutions:**
- Check runtime dispatcher is running (`orch_concurrency` > 0)
- Verify activities are being executed (`worker_concurrency` > 0)
- Increase timeout for remote databases (network latency)

---

## Delta from Previous Duroxide Version

### Changes in Commit `8e0952e`

Based on the git log, recent changes include:

1. **Refactor**: Renamed to `sqlite-stress` and consolidated structure
2. **Improvement**: Better retry logic in provider stress tests
3. **Feature**: Added `--track-cloud` option for cloud-specific result tracking
4. **Refactor**: Moved stress test infrastructure to core crate (reusable)

### Migration Notes

- ✅ Stress test framework is now in `duroxide::provider_stress_tests`
- ✅ Enable with `provider-test` feature (already enabled in duroxide-pg)
- ✅ `ProviderStressFactory` trait is the main integration point
- ✅ Results tracking pattern established in SQLite implementation

---

## Implementation Checklist

### Phase 1: Basic Infrastructure
- [ ] Create `pg-stress/` package directory
- [ ] Add `pg-stress/Cargo.toml` with dependencies
- [ ] Implement `PostgresStressFactory` in `pg-stress/src/lib.rs`
- [ ] Create CLI binary `pg-stress/src/bin/pg-stress.rs`
- [ ] Update workspace `Cargo.toml` to include `pg-stress`
- [ ] Test basic execution: `cargo run --package duroxide-pg-stress --bin pg-stress`

### Phase 2: Test Integration
- [ ] Create `tests/stress_tests.rs` with ignored test cases
- [ ] Add convenience script `scripts/run-pg-stress-tests.sh`
- [ ] Verify tests pass locally: `cargo test --test stress_tests -- --ignored`
- [ ] Verify tests pass on Azure: `DATABASE_URL=<azure> cargo test --test stress_tests -- --ignored`

### Phase 3: Result Tracking
- [ ] Create `pg-stress/track-results.sh` script
- [ ] Initialize `pg-stress/stress-test-results.md` baseline
- [ ] Initialize `pg-stress/stress-test-results-cloud.md` for Azure
- [ ] Run baseline tests and capture results
- [ ] Document expected performance ranges

### Phase 4: CI/CD Integration
- [ ] Add GitHub Actions workflow for stress tests
- [ ] Configure scheduled runs (weekly)
- [ ] Set up result artifact uploads
- [ ] Add performance regression detection

### Phase 5: Documentation
- [ ] Update main README with stress test instructions
- [ ] Document performance expectations and baselines
- [ ] Add troubleshooting guide for common issues
- [ ] Create comparison chart vs SQLite provider

---

## Expected Timeline

- **Phase 1 (Basic Infrastructure)**: 2-3 hours
- **Phase 2 (Test Integration)**: 1-2 hours
- **Phase 3 (Result Tracking)**: 1 hour
- **Phase 4 (CI/CD)**: 1-2 hours
- **Phase 5 (Documentation)**: 1 hour

**Total effort**: 1 day of focused work

---

## Success Criteria

### Minimum Viable Product (MVP)

1. ✅ Can run `cargo run --package duroxide-pg-stress --bin pg-stress`
2. ✅ Tests complete with 100% success rate
3. ✅ Results show throughput and latency metrics
4. ✅ Works against both local and remote PostgreSQL

### Production Ready

1. ✅ All MVP criteria met
2. ✅ CI/CD integration with automated runs
3. ✅ Result tracking over time with baselines
4. ✅ Performance regression detection
5. ✅ Comprehensive documentation

---

## Next Steps

1. **Immediate**: Create `pg-stress/` package and implement basic factory
2. **Short-term**: Run initial baseline tests and establish performance expectations
3. **Medium-term**: Integrate into CI/CD pipeline
4. **Long-term**: Add additional stress test scenarios (timers, sub-orchestrations, etc.)

---

## References

- [Duroxide Stress Test Spec](https://github.com/affandar/duroxide/blob/main/docs/stress-test-spec.md)
- [SQLite Stress Test Implementation](https://github.com/affandar/duroxide/tree/main/sqlite-stress)
- [Provider Testing Guide](https://github.com/affandar/duroxide/blob/main/docs/provider-testing-guide.md)

