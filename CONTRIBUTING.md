# Contributing to lish

lish and its tooling are separate repositories that build against each other
through sibling **path dependencies** (`build.zig.zon` uses `.path = "../lish"`),
so they must be cloned **side by side** in the same parent directory.

## 1. Clone the workspace

```sh
mkdir lish-workspace && cd lish-workspace
git clone https://github.com/mhogle25/lish.git
git clone https://github.com/mhogle25/lish-lsp.git
git clone https://github.com/mhogle25/folio.git
git clone https://github.com/mhogle25/tree-sitter-lish.git
```

Resulting layout (the sibling arrangement is required):

```
lish-workspace/
|-- lish/              # the language: CLI/REPL + embeddable library
|-- lish-lsp/          # language server (builds against ../lish)
|-- folio/             # dialogue/scripting layer (builds against ../lish)
`-- tree-sitter-lish/  # grammars (vendor generated constants from ../lish)
```

## 2. Get the toolchain

### Recommended: Nix (exact, reproducible, any OS)

With [Nix](https://nixos.org/download) installed and flakes enabled:

```sh
cd lish
nix develop
```

This drops you into a shell with the **exact pinned toolchain** (`zig 0.16.0`,
`node`, `pnpm`, `tree-sitter`) without installing anything system-wide. The
pinned Zig version is the point: every repo builds against one toolchain, so
there's no version drift. Exit the shell to return to your normal environment.

### Manual

Prefer to manage it yourself? You need `zig 0.16.0` (the exact version matters),
plus `node`, `pnpm`, and the `tree-sitter` CLI for grammar work.

## 3. Build & test

From inside the dev shell (or with the tools on PATH):

```sh
cd lish            && zig build test          # the language
cd ../lish-lsp     && zig build test          # the LSP (resolves ../lish)
cd ../folio        && zig build test          # folio (resolves ../lish)
cd ../tree-sitter-lish && pnpm install && pnpm test   # the grammars
```
