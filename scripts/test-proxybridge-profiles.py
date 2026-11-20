#!/usr/bin/env python3

import fnmatch
import json
import unittest
from pathlib import Path


PROJECT_DIRECTORY = Path(__file__).resolve().parent.parent
PROFILE_DIRECTORY = PROJECT_DIRECTORY / "proxybridge"
PROFILE_NAMES = ("BCS-VPN", "BCS-VPN-and-Tor")
SYSPASS_HOSTNAME = "ef-syspass.tusvc.t-global.bcs"


class ProxyBridgeProfileTests(unittest.TestCase):
    def test_syspass_uses_local_vpn_proxy(self):
        for profile_name in PROFILE_NAMES:
            for extension in ("json", "pbprofile"):
                profile_path = PROFILE_DIRECTORY / f"{profile_name}.{extension}"
                with self.subTest(profile=profile_path.name):
                    profile = json.loads(profile_path.read_text())
                    matching_rules = [
                        rule
                        for rule in profile["proxyRules"]
                        if rule["enabled"]
                        and rule["processNames"] == "*"
                        and rule["protocol"] in ("TCP", "BOTH")
                        and rule["targetPorts"] == "*"
                        and any(
                            fnmatch.fnmatchcase(SYSPASS_HOSTNAME, host_pattern.strip())
                            for host_pattern in rule["targetHosts"].split(";")
                        )
                    ]
                    self.assertTrue(
                        matching_rules,
                        f"{SYSPASS_HOSTNAME} is not covered by a VPN rule",
                    )
                    selected_proxy = next(
                        (
                            proxy
                            for proxy in profile["proxyConfigs"]
                            if proxy["id"] == matching_rules[0]["action"]
                        ),
                        None,
                    )
                    self.assertIsNotNone(selected_proxy)
                    self.assertEqual(selected_proxy["type"], "socks5")
                    self.assertEqual(selected_proxy["host"], "127.0.0.1")
                    self.assertEqual(selected_proxy["port"], 8889)

    def test_profile_copies_are_identical(self):
        for profile_name in PROFILE_NAMES:
            with self.subTest(profile=profile_name):
                self.assertEqual(
                    (PROFILE_DIRECTORY / f"{profile_name}.json").read_bytes(),
                    (PROFILE_DIRECTORY / f"{profile_name}.pbprofile").read_bytes(),
                )


if __name__ == "__main__":
    unittest.main()
