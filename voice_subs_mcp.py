#!/usr/bin/env python3
"""
MCP server for managing voice transcription substitutions.

TOOLS
=====
- list_subs()                  — Show all current substitutions
- add_sub(pattern, replacement) — Add a new substitution
- remove_sub(pattern)          — Remove a substitution by pattern
"""

import json
from pathlib import Path

from mcp.server import Server
import mcp.server.stdio
import mcp.types as types

SUBS_FILE = Path.home() / "pi-data" / "voice_subs.json"

server = Server("voice-subs")


def _load() -> list:
    if SUBS_FILE.exists():
        return json.loads(SUBS_FILE.read_text()).get("subs", [])
    return []


def _save(subs: list) -> None:
    SUBS_FILE.parent.mkdir(parents=True, exist_ok=True)
    SUBS_FILE.write_text(json.dumps({"subs": subs}, indent=2) + "\n")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="list_subs",
            description="List all voice transcription substitutions",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="add_sub",
            description="Add a voice transcription substitution. Pattern is a Lua regex (or plain text — use plain text unless you need regex). Example: add_sub('Jithub', 'GitHub')",
            inputSchema={
                "type": "object",
                "properties": {
                    "pattern":     {"type": "string", "description": "Text or Lua regex to match"},
                    "replacement": {"type": "string", "description": "What to replace it with"},
                },
                "required": ["pattern", "replacement"],
            },
        ),
        types.Tool(
            name="remove_sub",
            description="Remove a substitution by its pattern",
            inputSchema={
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "The pattern to remove"},
                },
                "required": ["pattern"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    def text(s: str) -> list[types.TextContent]:
        return [types.TextContent(type="text", text=s)]

    if name == "list_subs":
        subs = _load()
        if not subs:
            return text("No substitutions defined.")
        lines = [f"  {s['pattern']!r} → {s['replacement']!r}" for s in subs]
        return text("Substitutions:\n" + "\n".join(lines))

    elif name == "add_sub":
        pattern = arguments["pattern"]
        replacement = arguments["replacement"]
        subs = _load()
        # Update if pattern already exists, otherwise append
        for s in subs:
            if s["pattern"] == pattern:
                s["replacement"] = replacement
                _save(subs)
                return text(f"Updated: {pattern!r} → {replacement!r}")
        subs.append({"pattern": pattern, "replacement": replacement})
        _save(subs)
        return text(f"Added: {pattern!r} → {replacement!r}")

    elif name == "remove_sub":
        pattern = arguments["pattern"]
        subs = _load()
        before = len(subs)
        subs = [s for s in subs if s["pattern"] != pattern]
        if len(subs) == before:
            return text(f"No substitution found with pattern {pattern!r}")
        _save(subs)
        return text(f"Removed: {pattern!r}")

    return text(f"Unknown tool: {name}")


async def main():
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
