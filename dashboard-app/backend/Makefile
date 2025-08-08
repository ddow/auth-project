build-AuthFunction:
	pip install -r requirements.txt -t $(ARTIFACTS_DIR) --platform manylinux2014_x86_64 --only-binary=:all:
	cp main.py $(ARTIFACTS_DIR)/
	# Optional zip for remote deployment
	@if [ -d $(ARTIFACTS_DIR) ]; then \
		cd $(ARTIFACTS_DIR) && zip -r ../../auth_backend.zip . && echo "✅ Created auth_backend.zip in project root."; \
	else \
		echo "❌ Error: Artifacts directory not found, skipping zip creation."; \
	fi