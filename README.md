# Taxi Forecasting

Python application for two NYC taxi prediction tasks:

- **Demand:** pickup count for one pickup zone and hour.
- **Fare:** `fare_amount` for one trip, not the full passenger bill.

The repository includes data processing, XGBoost/LightGBM training, MLflow
tracking, FastAPI serving, recursive batch forecasts, SHAP explanations,
subgroup evaluation, drift detection, a Streamlit dashboard, and optional AWS
infrastructure templates. It contains no datasets or trained model bundles.

## Start Locally

For the preinstalled Windows course image, follow the
[AWS account and image-access guide](docs/STUDENT_AWS_IMAGE_ACCESS.md) instead of
recreating the environment with the local-install commands below.

Use Python 3.11. From the repository root on Windows PowerShell:

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m pytest
```

Tests use synthetic data and do not require downloads, models or AWS access.

## Golden Path: Run Everything End to End

From a clean clone, after creating `.venv` as above, one command runs every
local stage in order and stops at the first failure:

```powershell
.\scripts\run_all.ps1
```

| Stage | What runs | Evidence produced |
| --- | --- | --- |
| 1. Quality gate | `ruff check .` and `pytest` (same checks as CodeBuild) | Pass/fail in the log |
| 2. Data pipeline | Download January 2024 TLC data, clean, aggregate, build features, split by time | `data/processed/pipeline_summary.json`, `data/features/*.parquet` |
| 3. Training | XGBoost vs LightGBM per problem, select by validation RMSE, register winners | `mlflow.db`, `mlruns/`, SHAP plots under `artifacts/` |
| 4. Batch inference | Recursive 3-hour demand forecast | Rows appended to `predictions.db` |
| 5. Responsible AI | Subgroup error metrics, SHAP, model cards | `artifacts/responsible/`, `docs/model_cards/` |
| 6. Drift detection | Synthetic drift report for both models | `artifacts/drift/` |
| 7. Real-time serving | Start the API, wait for `status: ok`, run the smoke-test suite | Smoke-test JSON |

Each run writes `artifacts/logs/golden_path_<timestamp>.log` and a matching
`.json` summary containing the Git commit and every stage's status and duration.
Rerun faster with `-SkipDownload` (reuse cached raw data) and `-SkipTraining`
(reuse registered models). Training uses one Optuna trial per estimator by
default (`-NTrials` to change).
Follow [setup](docs/SETUP.md) to download data, train registered models, and
start the API and dashboard. Do not expect working predictions immediately
after cloning: serving requires both registered models and saved demand history.

## Documentation

- [Request and launch the Windows course image](docs/STUDENT_AWS_IMAGE_ACCESS.md)
- [Deploy the API to AWS with CodeBuild](docs/STUDENT_AWS_DEPLOYMENT_WALKTHROUGH.md)
- [Local setup and commands](docs/SETUP.md)
- [API request examples](docs/API_EXAMPLES.md)
- [System architecture](docs/ARCHITECTURE.md)
- [Data scope and model limitations](docs/DATA_STATEMENT.md)
- [Optional AWS infrastructure](infra/terraform/README.md)
- [Recording companion and learner activity map](docs/RECORDING_COMPANION.md)
- [Recorded architecture walkthrough](docs/PROJECT_ARCHITECTURE.md)
- [Historical business report](docs/BUSINESS_REPORT.md)
- [Cloud cost boundaries](docs/COST_OPTIMIZATION.md)

The companion links all L2-L12 learner labs; L1 uses setup and tests. Videos are
provided separately. Lab files, reviewed diagrams, and the exploration notebook
retain the paths shown in the recordings. The notebook has no saved outputs.
Datasets, trained models, and evidence reports must be generated locally; AWS
activities require your own authorized configuration or the stated local fallback.

## Layout

| Path | Responsibility |
| --- | --- |
| `src/data/`, `src/features/` | Download, clean, aggregate, engineer features, and split by time |
| `src/models/` | Tune, train, evaluate, explain, and register models |
| `src/serving/`, `clients/python/` | API contracts, inference, batch forecasting, and HTTP client |
| `src/monitoring/`, `src/responsible/` | Drift, performance comparisons, SHAP, and subgroup metrics |
| `scripts/` | Technical command entrypoints |
| `dashboard/` | Streamlit views calling the API and reading local reports |
| `tests/` | Offline unit and integration checks |
| `notebooks/`, `docs/` | Data exploration, learner activities, and technical references |
| `docker/`, `infra/terraform/`, `retraining/` | Optional packaging and cloud operation |

## Operational Boundaries

Docker, Terraform and AWS are optional for local operation. The cloud templates
are not connected to any account, remote repository or existing deployment.
They can create billable resources if you explicitly deploy them with credentials.
No GitHub Actions workflows or automatic release hooks are configured here.

Historical evaluation does not establish current production quality. The default
forecast follows the latest stored history, not the current clock. Model errors,
duration estimation, drift and subgroup disparities require review before using
predictions to make operational or financial decisions.