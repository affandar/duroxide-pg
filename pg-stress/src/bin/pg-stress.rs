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
    #[arg(short = 'u', long)]
    database_url: Option<String>,

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

    // Get database URL from args or environment
    let database_url = args
        .database_url
        .or_else(|| std::env::var("DATABASE_URL").ok())
        .expect("DATABASE_URL must be provided via --database-url or DATABASE_URL env var");

    // Run stress test suite
    run_test_suite(database_url, args.duration).await?;

    // TODO: Implement result tracking if --track or --track-cloud is set
    if args.track || args.track_cloud {
        eprintln!("Note: Result tracking not yet implemented for PostgreSQL provider");
    }

    Ok(())
}

