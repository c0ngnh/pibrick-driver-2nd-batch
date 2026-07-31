// workerscript.js — background worker for the piBrick autorotation plasmoid
//
// WorkerScript runs in a separate thread. Receives messages with a shell command
// and executes it via Process. Used as a fallback when Qt.labs.process isn't
// available in the QML environment.
//
// Usage:
//   WorkerScript { source: "workerscript.js" }
//   worker.sendMessage({ cmd: "/usr/bin/autorotation-lock", args: ["lock", "normal"] })
//   onMessage: { console.log(messageObject.output) }

WorkerScript.onMessage = function(message) {
    var cmd = message.cmd;
    var args = message.args || [];
    var out = "";
    var exitCode = 1;

    try {
        var proc = Qt.createQmlObject(
            "import QtCore 1.0; QtProcess { }",
            WorkerScript, "QtProcess"
        );
        if (proc) {
            proc.start(cmd, args);
            proc.waitForFinished(500);
            out = proc.readAllStandardOutput().trim();
            exitCode = proc.exitCode();
            proc.close();
        } else {
            // No Process available — this shouldn't happen in a Plasma environment
            out = "ERROR: no Process available";
        }
    } catch(e) {
        out = "ERROR: " + e.message;
    }

    WorkerScript.sendMessage({
        id: message.id || 0,
        cmd: cmd,
        output: out,
        exitCode: exitCode
    });
};
