//
//  main.swift
//  CmdSpace
//
//  Created by Dmitry Yurkovski on 18/04/2026.
//

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
