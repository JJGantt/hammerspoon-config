#!/usr/bin/env python3
"""
MCP server for managing voice transcription substitutions.

TOOLS
=====
- list_subs()                 — Show all current substitutions
- add_sub(word, replacement)  — Add a case-insensitive substitution (plain text input)
- remove_sub(word)            — Remove a substitution by plain word
"""

import json
from pathlib import Path

from mcp.server import Server
import mcp.server.stdio
import mcp.types as types

SUBS_FILE = Path.home() / "pi-data" / "voice_subs.json"

server = Server("voice-subs")

# Lua pattern magic characters that need escaping
_LUA_MAGIC = set(r"()%.+*?[]^$-")


def _to_lua_ci_pattern(word: str) -> str:
    """Convert a plain word/phrase to a case-insensitive Lua pattern.

    'jit'     → '[Jj][Ii][Tt]'
    'git hub' → '[Gg][Ii][Tt] [Hh][Uu][Bb]'
    """
    result = []
    for ch in word:
        if ch.isalpha():
            result.append(f"[{ch.upper()}{ch.lower()}]")
        elif ch in _LUA_MAGIC:
            result.append("%" + ch)
        else:
            result.append(ch)
    return "".join(result)


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
            description=(
                "Add a case-insensitive voice transcription substitution. "
                "Pass plain text — the Lua pattern is generated automatically. "
                "Example: add_sub('jit', 'git') or add_sub('jithub', 'GitHub')"
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "word":        {"type": "string", "description": "Plain text word/phrase to match (case-insensitive)"},
                    "replacement": {"type": "string", "description": "What to replace it with"},
                },
                "required": ["word", "replacement"],
            },
        ),
        types.Tool(
            name="remove_sub",
            description="Remove a substitution by its plain word (same value passed to add_sub)",
            inputSchema={
                "type": "object",
                "properties": {
                    "word": {"type": "string", "description": "The plain word to remove"},
                },
                "required": ["word"],
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
        lines = [f"  {s.get('word', s['pattern'])!r} → {s['replacement']!r}" for s in subs]
        return text("Substitutions:\n" + "\n".join(lines))

    elif name == "add_sub":
        word = arguments["word"].lower()
        replacement = arguments["replacement"]
        pattern = _to_lua_ci_pattern(word)
        subs = _load()
        for s in subs:
            if s.get("word") == word:
                s["replacement"] = replacement
                s["pattern"] = pattern
                _save(subs)
                return text(f"Updated: {word!r} → {replacement!r}")
        subs.append({"word": word, "pattern": pattern, "replacement": replacement})
        _save(subs)
        return text(f"Added: {word!r} → {replacement!r}  (pattern: {pattern})")

    elif name == "remove_sub":
        word = arguments["word"].lower()
        subs = _load()
        before = len(subs)
        subs = [s for s in subs if s.get("word") != word]
        if len(subs) == before:
            return text(f"No substitution found for {word!r}")
        _save(subs)
        return text(f"Removed: {word!r}")

    return text(f"Unknown tool: {name}")


async def main():
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
