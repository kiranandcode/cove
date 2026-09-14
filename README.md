# Cove: Live Terminals in a 2D World

Cove is an interface for managing many terminals running coding agents,
or "Termlings".

## Setup

Install [Godot](https://godotengine.org/download) to Applications. Then: 

```
brew install abduco
git checkout cove
./dev.sh build
GODOT=/Applications/Godot.app/Contents/MacOS/Godot ./cove/dev.sh
```

## Quickstart

| Action | Control |
|---|---|
| Zoom | Scroll over empty ground |
| Navigate | Drag on empty ground |
| Create Termling | Cmd+N |
| Focus Termling | Click it | 
| Create a region (keeps Termlings inside) | Cmd+drag  |
| Name Termling | Right-click it |
| Find Termling | Cmd+F |
