# BluettiBar 2.0.5: real macOS E2E evidence capture

This package is the original 2.0.5 source plus `capture-real-e2e.command`,
which captures **real** PNG files only when executed in a logged-in graphical
**macOS** session. It does not render, draw or fabricate any screenshot.

Run `./capture-real-e2e.command` inside the unpacked folder on a disposable
macOS GUI machine. The script installs the app and runs the native UI/logic
self-tests, captures the top menu bar, attempts a real accessibility click of the
BluettiBar icon, captures the opened menu, terminates and relaunches the app,
queries Spotlight indexing and captures a Spotlight search, and attempts the
real app's separately labelled `--demo` mode for the graph's populated state.

The Mac must grant the runner Screen Recording and Accessibility permissions.
The tests cannot bypass operating-system permissions. `results.txt` explicitly
records failed/unavailable actions; no source-code check or screenshot existence
is counted as visual E2E success. The screenshots must be visually inspected to
establish actual adjacency to the clock, layout correctness, graph axes and
Spotlight's visible search result. Status-item accessibility depends on the
macOS version and the user's menu-bar configuration.

**Not yet run on real macOS in the automation's Linux container.** The user
requested genuine PNGs; none are included because none have yet been captured.
Do not mistake the local parser/asset checks for an executed E2E test.
