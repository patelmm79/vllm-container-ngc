
import base64
import json
from google.cloud import logging_v2

def handle_build_notification(event, context):
    """
    Cloud Function triggered by a Pub/Sub message from Cloud Build.
    """
    # The actual message is Base64 encoded in the 'data' field
    if 'data' not in event:
        print("No data in event, skipping.")
        return

    try:
        message_data = base64.b64decode(event['data']).decode('utf-8')
        build_info = json.loads(message_data)
        status = build_info.get('status')
        build_id = build_info.get('id')

        print(f"Received build notification for build ID: {build_id} with status: {status}")

        # We only care about failed or timed-out builds
        if status not in ('FAILURE', 'TIMEOUT'):
            print(f"Build status is {status}, not a failure. Skipping.")
            return

        print(f"Build {build_id} failed. Fetching logs...")
        logs = get_build_logs(build_id)

        if logs:
            print(f"--- Logs for failed build: {build_id} ---")
            print(logs)
            print("--- End of logs ---")

            # This is where you would call the Gemini API
            # For example:
            # prompt = f"The following build failed. Analyze the logs and suggest a fix.\n\nLogs:\n{logs}"
            # analysis = call_gemini_api(prompt)
            # print(f"Gemini Analysis: {analysis}")

        else:
            print("Could not retrieve logs.")

    except Exception as e:
        print(f"Error processing build notification: {e}")


def get_build_logs(build_id: str) -> str:
    """
    Retrieves the logs for a specific Cloud Build ID from Cloud Logging.
    """
    try:
        client = logging_v2.LoggingServiceV2Client()
        # The filter to find logs for a specific build
        log_filter = f'resource.type="build" AND resource.labels.build_id="{build_id}"'
        
        # The name of the parent resource to receive logs from
        # You might need to adjust this if your project is in a different folder/org
        project_id = "globalbiting-dev" # Hardcoding for simplicity, could be env var
        resource_name = f"projects/{project_id}"

        # Retrieve log entries
        entries = client.list_log_entries(
            resource_names=[resource_name],
            filter_=log_filter,
            order_by="timestamp asc"
        )

        log_lines = []
        for entry in entries:
            # The log message is in text_payload
            if entry.text_payload:
                log_lines.append(entry.text_payload)
        
        return "\n".join(log_lines)

    except Exception as e:
        print(f"Error fetching logs for build {build_id}: {e}")
        return ""

