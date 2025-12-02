#!/usr/bin/env python3
"""
API Key Management Script

This script helps you manage API keys stored in Google Secret Manager.

Usage:
    # Create the secret (first time only)
    python manage_api_keys.py create-secret --project PROJECT_ID

    # Generate and add a new API key
    python manage_api_keys.py add-key --project PROJECT_ID --name "service-a"

    # List all API keys (names only, not the actual keys)
    python manage_api_keys.py list-keys --project PROJECT_ID

    # Remove an API key
    python manage_api_keys.py remove-key --project PROJECT_ID --name "service-a"

    # Rotate a key (generates new key for existing name)
    python manage_api_keys.py rotate-key --project PROJECT_ID --name "service-a"
"""

import argparse
import json
import secrets
from typing import Dict

from google.cloud import secretmanager
from google.api_core import exceptions


SECRET_NAME = "vllm-api-keys"


def generate_api_key() -> str:
    """Generate a secure random API key."""
    return f"sk-{secrets.token_urlsafe(32)}"


def get_secret_client():
    """Get Secret Manager client."""
    return secretmanager.SecretManagerServiceClient()


def create_secret(project_id: str):
    """
    Create the API keys secret in Secret Manager.
    This only needs to be run once.
    """
    client = get_secret_client()
    parent = f"projects/{project_id}"

    try:
        # Check if secret already exists
        secret_path = f"{parent}/secrets/{SECRET_NAME}"
        client.get_secret(request={"name": secret_path})
        print(f"✓ Secret '{SECRET_NAME}' already exists")
        return
    except exceptions.NotFound:
        pass

    # Create the secret
    secret = client.create_secret(
        request={
            "parent": parent,
            "secret_id": SECRET_NAME,
            "secret": {
                "replication": {"automatic": {}},
            },
        }
    )

    print(f"✓ Created secret: {secret.name}")

    # Add initial empty version
    initial_data = json.dumps({}).encode("UTF-8")
    client.add_secret_version(
        request={
            "parent": secret.name,
            "payload": {"data": initial_data},
        }
    )

    print(f"✓ Initialized secret with empty key list")


def get_current_keys(project_id: str) -> Dict[str, str]:
    """Get current API keys from Secret Manager."""
    client = get_secret_client()
    secret_path = f"projects/{project_id}/secrets/{SECRET_NAME}/versions/latest"

    try:
        response = client.access_secret_version(request={"name": secret_path})
        data = response.payload.data.decode("UTF-8")
        return json.loads(data)
    except exceptions.NotFound:
        print(f"✗ Secret '{SECRET_NAME}' not found. Run 'create-secret' first.")
        exit(1)
    except json.JSONDecodeError:
        print(f"✗ Secret data is not valid JSON")
        exit(1)


def update_keys(project_id: str, keys: Dict[str, str]):
    """Update API keys in Secret Manager."""
    client = get_secret_client()
    parent = f"projects/{project_id}/secrets/{SECRET_NAME}"

    payload = json.dumps(keys, indent=2).encode("UTF-8")

    client.add_secret_version(
        request={
            "parent": parent,
            "payload": {"data": payload},
        }
    )


def add_key(project_id: str, name: str):
    """Add a new API key."""
    keys = get_current_keys(project_id)

    if name in keys:
        print(f"✗ Key '{name}' already exists. Use 'rotate-key' to replace it.")
        return

    new_key = generate_api_key()
    keys[name] = new_key

    update_keys(project_id, keys)

    print(f"✓ Added new API key: {name}")
    print(f"\nAPI Key: {new_key}")
    print(f"\nStore this key securely - it won't be shown again!")
    print(f"Use it in requests with header: X-API-Key: {new_key}")


def list_keys(project_id: str):
    """List all API key names (not the actual keys)."""
    keys = get_current_keys(project_id)

    if not keys:
        print("No API keys found")
        return

    print(f"API Keys ({len(keys)} total):")
    for i, name in enumerate(keys.keys(), 1):
        print(f"  {i}. {name}")


def remove_key(project_id: str, name: str):
    """Remove an API key."""
    keys = get_current_keys(project_id)

    if name not in keys:
        print(f"✗ Key '{name}' not found")
        return

    del keys[name]
    update_keys(project_id, keys)

    print(f"✓ Removed API key: {name}")


def rotate_key(project_id: str, name: str):
    """Rotate (replace) an existing API key."""
    keys = get_current_keys(project_id)

    if name not in keys:
        print(f"✗ Key '{name}' not found. Use 'add-key' to create it.")
        return

    new_key = generate_api_key()
    keys[name] = new_key

    update_keys(project_id, keys)

    print(f"✓ Rotated API key: {name}")
    print(f"\nNew API Key: {new_key}")
    print(f"\nStore this key securely - it won't be shown again!")
    print(f"Use it in requests with header: X-API-Key: {new_key}")


def main():
    parser = argparse.ArgumentParser(
        description="Manage API keys for vLLM service",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # create-secret command
    create_parser = subparsers.add_parser(
        "create-secret",
        help="Create the API keys secret (first time setup)"
    )
    create_parser.add_argument("--project", required=True, help="GCP Project ID")

    # add-key command
    add_parser = subparsers.add_parser("add-key", help="Add a new API key")
    add_parser.add_argument("--project", required=True, help="GCP Project ID")
    add_parser.add_argument("--name", required=True, help="Name for the API key (e.g., 'service-a')")

    # list-keys command
    list_parser = subparsers.add_parser("list-keys", help="List all API key names")
    list_parser.add_argument("--project", required=True, help="GCP Project ID")

    # remove-key command
    remove_parser = subparsers.add_parser("remove-key", help="Remove an API key")
    remove_parser.add_argument("--project", required=True, help="GCP Project ID")
    remove_parser.add_argument("--name", required=True, help="Name of the API key to remove")

    # rotate-key command
    rotate_parser = subparsers.add_parser("rotate-key", help="Rotate (replace) an API key")
    rotate_parser.add_argument("--project", required=True, help="GCP Project ID")
    rotate_parser.add_argument("--name", required=True, help="Name of the API key to rotate")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return

    if args.command == "create-secret":
        create_secret(args.project)
    elif args.command == "add-key":
        add_key(args.project, args.name)
    elif args.command == "list-keys":
        list_keys(args.project)
    elif args.command == "remove-key":
        remove_key(args.project, args.name)
    elif args.command == "rotate-key":
        rotate_key(args.project, args.name)


if __name__ == "__main__":
    main()
