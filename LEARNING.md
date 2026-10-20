# Learning Notes

A short summary of what has been run so far and what each step means.

## The big idea

Machine learning learns patterns from past examples to predict new cases. This
project learns from about 2.7 million January 2024 NYC taxi trips to answer two
questions:

- **Demand:** how many pickups will a zone get in a given hour?
- **Fare:** what will one trip's `fare_amount` be?

## Phase 1: Data pipeline

`.\.venv\Scripts\python.exe -m scripts.run_pipeline --year 2024 --month 1` (27 seconds)

1. **Download** the official TLC trip file (one row per trip).
2. **Clean** impossible rows. 2,964,624 trips in, 2,727,349 kept (92%). The biggest
   removal was 167,879 rows with invalid passenger counts.
3. **Branch** into two datasets: hourly pickup counts per zone (demand) and one row
   per trip (fare).
4. **Build features**, the inputs the model sees. Demand uses lags (pickups 1, 24 and
   168 hours earlier), rolling averages and calendar values. Fare uses distance,
   duration, zones, hour and passenger count.
5. **Split by date** into train (80%, to learn from), validation (10%, to choose the
   model) and test (10%, for one final honest score). Splitting by date rather than
   randomly copies real life: you always predict the future from the past.

## Phase 2: Training

`.\.venv\Scripts\python.exe -m scripts.train_models --n-trials 1` (about 3 minutes)

- **XGBoost and LightGBM** both build hundreds of small decision trees, each one
  correcting the mistakes of the trees before it ("boosting").
- **`--n-trials 1`** means Optuna tries one combination of settings per model.
- **The winner is chosen by validation score only.** The test score is never used
  for choosing, so it stays an honest exam.
- **MLflow** records every run. The winner is **registered** under a fixed name, and
  the API loads models by those names.

| Metric | Meaning | Better |
| --- | --- | --- |
| RMSE | Typical error in the answer's units; big misses count extra | Lower |
| MAE | Plain average error | Lower |
| R² | Share of the variation the model explains (1.0 = perfect) | Higher |

| Problem | Winner | Test RMSE | Test MAE | Test R² |
| --- | --- | --- | --- | --- |
| Demand | LightGBM | 8.70 pickups | 2.53 | 0.971 |
| Fare | LightGBM | $3.47 | $0.82 | 0.955 |

Demand MAPE looks high (about 42%) because many zone-hours have only 0 to 2
pickups, where an error of one pickup is a large percentage.

**SHAP** shows which inputs drive predictions. For fare, trip distance matters most,
then trip duration. For demand, the previous hour matters most, then the same hour
last week (lag 168), then the same hour yesterday.

## Phase 3: Serving

`.\.venv\Scripts\python.exe -m uvicorn src.serving.api:app --host 127.0.0.1 --port 8000`

- **API** means a web service: send trip details, get a prediction back. Swagger at
  `http://127.0.0.1:8000/docs` lets you send requests by clicking.
- **`/health`** returned `status: ok`, both models loaded, 744 history hours, 253 zones.
  The API can return HTTP 200 with `status: degraded` when models fail to load, so
  always read the body.
- **Fare:** 17 miles from JFK (132) to Times Square (230) predicted **$70.80**. The real
  JFK to Manhattan flat fare in January 2024 was $70, which the model learned from data.
- **Demand:** targets must sit just after the data ends (Feb 1, 2024), because the
  model needs the hours before the target.
- **Recursive forecast:** to predict several hours ahead, each predicted hour is fed
  back in as history for the next. Errors grow with distance, so keep horizons short.

## Phase 3: Batch inference

`.\.venv\Scripts\python.exe -m scripts.batch_forecast --horizon 3` (about 2 minutes)

- **Real-time** answers one question at once. **Batch** predicts everything on a
  schedule and stores it.
- `predictions.db` is a file that works like a spreadsheet table (a SQLite database).
  Each row is one prediction: one zone, one future hour, predicted pickups.
- The job predicted 253 zones for each of 3 hours ahead (Feb 1, 00:00 to 02:00), so
  253 x 3 = 759 rows.
- Every row is also labelled with `generated_at` (when the prediction was made, not
  the hour being predicted) and `model_version` (which model made it). These labels
  let you trace any prediction back to the run and model that produced it.
- Busiest at midnight: JFK, Greenwich Village, Hell's Kitchen, Times Square,
  West Village.
- Each run adds rows rather than replacing earlier ones.

## Supporting work

- Pinned `sqlalchemy<2.1` because SQLAlchemy 2.1 broke MLflow 2.14.1.
- Installed AWS CLI and Terraform.
- Added `scripts/run_all.ps1` (one command runs every stage, for Phase 8) and a
  Golden Path section in the README.
- Logs for the video are saved under `artifacts/logs/` (not committed).

## Next

Responsible AI analysis, drift report, dashboard, a full golden-path run, a local
Docker check, commit and push, then the AWS deployment and the video.
