import copy
import unittest

try:
    from Tools.verify_native_test_execution import verify
except ModuleNotFoundError:
    from verify_native_test_execution import verify


class NativeTestExecutionTests(unittest.TestCase):
    def setUp(self):
        self.summary = {"passedTests": 2, "failedTests": 0, "skippedTests": 0}
        self.selectors = ["-only-testing:AppTests", "-only-testing:AppUITests/UITests/testSave"]
        self.logic = self.case("AppTests/LogicTests/prices()")
        self.ui = self.case("AppUITests/UITests/testSave")
        self.tree = {"testNodes": [{"nodeType": "Test Plan", "children": [self.logic, self.ui]}]}

    @staticmethod
    def case(identity):
        return {"nodeType": "Test Case", "result": "Passed",
                "nodeIdentifierURL": "test://com.apple.xcode/App/" + identity}

    def test_exact_requested_tests_pass(self):
        self.assertEqual(verify(self.summary, self.tree, self.selectors),
                         {"verifiedSelectors": 2, "passedTestCases": 2})

    def test_green_summary_cannot_hide_an_omitted_ui_test(self):
        self.tree["testNodes"][0]["children"] = [self.logic]
        self.summary["passedTests"] = 1365
        with self.assertRaisesRegex(ValueError, "AppUITests/UITests/testSave"):
            verify(self.summary, self.tree, self.selectors)

    def test_zero_executed_is_not_success(self):
        self.summary["passedTests"] = 0
        with self.assertRaises(ValueError):
            verify(self.summary, {"testNodes": []}, self.selectors)

    def test_wrong_target_same_method_does_not_match(self):
        self.ui["nodeIdentifierURL"] = "test://com.apple.xcode/App/OtherUITests/UITests/testSave"
        with self.assertRaisesRegex(ValueError, "not executed"):
            verify(self.summary, self.tree, self.selectors)

    def test_missing_unknown_skipped_and_failed_results_fail_closed(self):
        for result in (None, "Skipped", "Failed", "Unknown"):
            with self.subTest(result=result):
                self.ui["result"] = result
                with self.assertRaises(ValueError):
                    verify(self.summary, self.tree, self.selectors)

    def test_summary_failure_skip_or_invalid_counts_are_rejected(self):
        for field, value in (("failedTests", 1), ("skippedTests", 1), ("passedTests", True),
                             ("passedTests", "2"), ("passedTests", -1), ("failedTests", None)):
            summary = dict(self.summary, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                verify(summary, self.tree, self.selectors)

    def test_tree_and_identity_must_be_present(self):
        for tree in ({}, {"testNodes": []}, {"testNodes": [None]}, {"testNodes": "Passed"}):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                verify(self.summary, tree, self.selectors)
        for identity in ("", "AppUITests/UITests/testSave", "https://com.apple.xcode/App/AppUITests/UITests/testSave"):
            tree = copy.deepcopy(self.tree)
            tree["testNodes"][0]["children"][1]["nodeIdentifierURL"] = identity
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                verify(self.summary, tree, self.selectors)

    def test_selectors_cannot_be_empty_duplicate_or_malformed(self):
        for selectors in ([], [self.selectors[0]] * 2, ["-only-testing:"], ["AppTests"]):
            with self.subTest(selectors=selectors), self.assertRaises(ValueError):
                verify(self.summary, self.tree, selectors)

    def test_encoded_target_names_and_parenthesized_identifiers(self):
        self.ui["nodeIdentifierURL"] = "test://com.apple.xcode/App/GunnAire%20OpsUITests/UITests/testSave()"
        selectors = ["-only-testing:AppTests", "-only-testing:GunnAire OpsUITests/UITests/testSave"]
        self.assertEqual(verify(self.summary, self.tree, selectors)["verifiedSelectors"], 2)


if __name__ == "__main__":
    unittest.main()
