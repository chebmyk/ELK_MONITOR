macOS tar.gz archive

Example (CLI):

> curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-9.4.1-darwin-x86_64.tar.gz

👉 For Apple Silicon (M1/M2):

> curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-9.4.1-darwin-aarch64.tar.gz

📂 2. Extract Archive

> tar -xzf filebeat-9.4.1-darwin-*.tar.gz

> cd filebeat-9.4.1-darwin-aarch64

📁 3. Understand Folder Structure
filebeat-8.x.x-darwin/
├── filebeat            ← binary
├── filebeat.yml        ← config
├── modules.d/
├── data/               ← registry
├── logs/

👉 Everything is self-contained (no system install)

⚙️ 4. Configure Filebeat

Edit config:

> vi filebeat.yml


🧪 5. Test Config
> ./filebeat test config

🔌 6. Test Connection to Logstash
> ./filebeat test output

▶️ 7. Run Filebeat

Foreground (recommended first):

> ./filebeat -e

👉 You should see:

Harvester started
Events sent