FarmTracker

Author: mobpsycho

Description: A clean and simple farming tracker for FFXI (Ashita v4). Tracks mobs, drops, gil, and gives you drop rates. Has a clean UI with a mini mode.

What It Does:

FarmTracker keeps track of your farming sessions in real time:

Tracks mob kills (including which mob dropped what)

Tracks item drops + who dropped it

Tracks items actually obtained (vs just dropped)

Tracks gil earned

Calculates drop rates based on actual kills

Has pricing logic and total gil value calculations

UI comes with full window and mini overlay mode

Saves your settings and session stats

How To Use It:

Commands

Use /farm in-game to control the addon:

/farm	Toggles the main UI window

/farm start	Starts a new farming session

/farm stop	Ends the current session

/farm mini	Toggles the small/minimal UI mode

/farm debug	Enables/disables debug logging

/farm test	Adds fake data for testing

/farm help	Prints the command list again

How It Works:

Session starts when you hit your first kill. That starts the timer.

Every mob kill is tracked by name.

Every item dropped is tracked — including who dropped it.

You’ll get drop rates per item, per mob.

Gil from drops is tracked, and you can assign gil values to items too.

UI shows totals, breakdowns, and session summaries.

Everything gets saved to JSON under your addon folder.

UI Features:

Toggle between full and mini mode.

Tabs for:

Mobs killed

Items obtained/dropped

Pricing and total value

Editable price list for estimating session value

Tooltip hints for settings

Notes:

Session data isn’t persisted (yet) across loads — that part is marked TODO.

If you want to tweak item prices for gil value tracking, go to the Prices tab.

Double-click the mini window to switch back to normal view.

Setup:

Drop the farmtracker.lua in your \Ashita\addons\farmtracker\ folder.

Make sure you create the folder if it doesn't exist.

No extra dependencies beyond what's available in Ashita:

Final Thoughts

FarmTracker is lightweight, no-nonsense, and does exactly what it says.

If you're grinding mobs and want a breakdown of what you're actually getting for your time — this is for you.

Coming Soon:

Analytics tab

This will save each session. This will allow you to view each session to compare droprates or comparing THrates. 

This will also store weekly and monthly to compare weeks and months.
