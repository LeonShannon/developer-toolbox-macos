import AppKit

let app = NSApplication.shared
let toolbox = Toolbox()
app.delegate = toolbox
app.run()
