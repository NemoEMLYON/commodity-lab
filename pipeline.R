# pipeline.R — Run the offline pipeline, step by step.
# Run from the project root: source("pipeline.R")

source("R/01_data.R")

# Step 1 — raw data (downloaded once, then read from data/raw/)
raw <- download_all()
print(summarise_data(raw))
