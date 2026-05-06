// config/quickshell/shell.qml
// =============================================================================
// RaBbLE Shell — Quickshell root
// Entry point: sources the bar and launcher layers.
// All components are in bar/, launcher/, widgets/.
// =============================================================================

import Quickshell
import Quickshell.Io
import qs.bar
import qs.launcher
import qs.widgets
import QtQuick

ShellRoot {
    // ── Bar (one per monitor) ─────────────────────────────────────────────────
    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData

            RaBbLEBar {
                screen: modelData
            }
        }
    }

    // ── Launcher overlay (single, floats above all) ───────────────────────────
    RaBbLELauncher {
        id: launcher
    }

    // ── IPC: listen for toggle signals from keybinds ──────────────────────────
    IpcHandler {
        target: "launcher"
        function toggle() { launcher.toggle() }
    }
}
