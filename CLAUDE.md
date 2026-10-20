# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

NYC taxi MLOps project with two regression problems: **demand** (pickups per zone per hour) and **fare** (`fare_amount` per trip, not the total bill). Data pipeline → XGBoost/LightGBM training with MLflow registry → FastAPI + batch serving → CodeBuild/ECR/ECS on AWS, plus drift, responsible-AI and Streamlit dashboard. It is a BITS capstone fork of `ashishnitk/taxi-forecasting-student` (remote `upstream`); `origin` is the user's public repo.

## Commands

Windows PowerShell, Python 3.11, from the repo root. Always call the venv interpreter explicitly (no activation needed):

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m pytest                                   # all tests (synthetic data, offline)
.\.venv\Scripts\python.exe -m pytest tests/unit/test_serving.py::test_name   # single test
.\.venv\Scripts\python.exe -m pytest --cov=src --cov-report=term-missing     # coverage gate (fail_under=75), as CodeBuild runs it
.\scripts\ci_local.ps1                     # ruff + pytest/coverage + terraform fmt/validate (mirrors CI)
.\scripts\run_all.ps1                      # golden path: every stage end to end, logs to artifacts/logs/
.\scripts\run_all.ps1 -SkipDownload -SkipTraining
```

Pipeline stages (each is also a step of `run_all.ps1`):

```powershell
.\.venv\Scripts\python.exe -m scripts.run_pipeline --year 2024 --month 1   # first run must download; later runs may add --skip-download
.\.venv\Scripts\python.exe -m scripts.train_models --n-trials 1            # trains both problems AND registers winners; default is 25 trials
.\.venv\Scripts\python.exe -m uvicorn src.serving.api:app --host 127.0.0.1 --port 8000   # Swagger at /docs, Prometheus at /metrics
.\.venv\Scripts\python.exe -m scripts.batch_forecast --horizon 3          # all zones, appends to predictions.db (~2 min)
.\.venv\Scripts\python.exe -m scripts.responsible.run_analysis            # writes artifacts/responsible/ and docs/model_cards/
.\.venv\Scripts\python.exe -m scripts.monitoring.demo_drift_report --problem all --mode drift
.\.venv\Scripts\python.exe -m mlflow ui --backend-store-uri sqlite:///mlflow.db --port 5000
```

Dashboard needs `requirements-dashboard.txt`, `$env:API_BASE_URL`, and the analysis outputs: `.\.venv\Scripts\python.exe -m streamlit run dashboard/app.py`.

## Architecture

**Data flow.** `src/data` downloads TLC Parquet, cleans it against the bounds in `config/config.yaml`, and branches into two datasets: dense hourly zone counts (`data/processed/demand_hourly.parquet`) and per-trip fare rows. `src/features` adds demand lags `[1,2,3,24,168]` / rolling windows and fare trip/calendar features; `src/data/splits.py` splits **chronologically** 80/10/10. None of `data/`, `mlflow.db`, `mlruns/`, `artifacts/`, `predictions.db` is in Git.

**Training** (`scripts/train_models.py` → `src/models/train.py` → `tuning.py`): Optuna-tunes each estimator, selects the winner by **validation** RMSE only (test metrics are logged but must never drive selection), logs runs to MLflow (`sqlite:///mlflow.db`), registers the winner as `taxi-demand-forecaster` / `taxi-fare-predictor`, and writes SHAP plots and model cards under `artifacts/<problem>/`. `--no-register` produces runs the API cannot serve.

**Serving.** `src/serving/service.py` holds a process-wide `ModelService` singleton (both models + demand history) loaded from the registry via `registry.py` using `models:/<name>/<serving.model_stage>` (default `latest`). `serving/features.py` reuses the training feature builders to avoid train/serve skew; demand requests rebuild lag/rolling features from the stored history, so targets must sit just after the history end (Feb 2024 for the default data). `/forecast/demand` is recursive (later hours consume earlier predictions). If loading fails at startup, the API still starts and `/health` returns **HTTP 200 with `status: degraded`** — readiness must be judged from the body, not the status code. Tests inject in-process models with `service.set_service(...)` (see `tests/conftest.py`).

**Config.** `src/config.py` loads `config/config.yaml` with env overrides (`TLC_TRIP_YEAR`, `MLFLOW_TRACKING_URI`, `MLFLOW_ARTIFACT_ROOT`, …) and caches it with `lru_cache` — env changes after first `get_config()` in a process are not seen.

**Delivery (AWS).** The API image is self-contained: `docker/Dockerfile` bakes `mlruns/`, the demand parquet, and `mlflow.container.db` (produced by `scripts/make_mlflow_portable.py`, which rewrites the Windows absolute artifact paths in `mlflow.db` to `/app/mlruns`). Because models are gitignored, `buildspec.yml` pulls them from an S3 bucket populated by `scripts/aws/upload_artifacts.ps1`. CodeBuild always runs ruff + pytest/coverage; it builds/pushes/rolls ECS only on pushes to `DEPLOY_BRANCH` **or any manual build start**. Terraform (`infra/terraform`, local state) creates ECR/ECS Fargate/ALB from the default VPC; optional stacks (monitoring, datalake, dashboard, cicd) are feature-flagged. `IMAGE_TAG` is fixed at `terraform apply` time, so later webhook builds reuse that tag. The student deployment runbook is `docs/STUDENT_AWS_DEPLOYMENT_WALKTHROUGH.md` (bootstrap with `desired_count=0`, build, then scale to 1).

## Repo-specific notes

- `sqlalchemy<2.1` is pinned in `requirements.txt` because `mlflow==2.14.1` imports a pool class removed in SQLAlchemy 2.1.
- Lab docs, diagrams and the notebook keep the paths shown in course recordings (README) — don't rename them. `scripts/build_explore_notebook.py` overwrites the notebook.
- `docs/class-transcripts/` is gitignored on purpose (contains AWS account IDs and classmates' names; the repo is public). `*.tfvars` (except `.example`) and Terraform state are also gitignored — never commit them, and don't delete local state before `terraform destroy`.
- Analysis commands overwrite their report folders; batch forecasts append rather than replace.

## Running commands
Before running any command, explain in plain language:
1. What the command does, including what each flag means
2. Why it's needed for the current task
3. What it will change (files, database, MLflow runs, processes) and whether it's reversible
Then wait for my approval. Never chain several risky commands into one.

## About me
I'm an experienced Java/Spring Boot developer, new to Python and ML.
- Explain Python concepts by comparing them to Java equivalents
- Explain ML terms the first time they appear, in plain language
- Before changing code, explain what the existing code does and why
- Prefer small, readable changes over clever one-liners