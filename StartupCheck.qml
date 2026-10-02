import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("simNetwork.check.nmcli", ["env", "LC_ALL=C", "nmcli", "--version"], (output, code) => {
            if (code !== 0) {
                done({ "title": "nmcli is required", "details": "Install NetworkManager and start its service." });
                return;
            }
            Proc.runCommand("simNetwork.check.mmcli", ["mmcli", "--version"], (mmOutput, mmCode) => {
                if (mmCode !== 0) {
                    done({ "title": "mmcli is required", "details": "Install ModemManager and start its service." });
                    return;
                }
                done(null);
            });
        });
    }
}
