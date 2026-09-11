"""Independent coverage oracle retained from local-worker qualification."""
import copy
import unittest

try:
    from Tools.verify_native_test_execution import verify
except ModuleNotFoundError:
    from verify_native_test_execution import verify


class WorkerCountContract(unittest.TestCase):
    def fixture(self):
        case = {"nodeType": "Test Case", "result": "Passed",
                "nodeIdentifierURL": "test://com.apple.xcode/App/AppTests/Logic/testReal()"}
        return {"passedTests": 1, "failedTests": 0, "skippedTests": 0}, {"testNodes": [case]}, ["-only-testing:AppTests"]

    def test_summary_cannot_inflate_real_executions(self):
        summary, tree, selectors = self.fixture()
        summary["passedTests"] = 99
        with self.assertRaises(ValueError):
            verify(summary, tree, selectors)

    def test_tree_cannot_duplicate_same_identity_to_inflate_executions(self):
        summary, tree, selectors = self.fixture()
        tree["testNodes"].append(copy.deepcopy(tree["testNodes"][0]))
        summary["passedTests"] = 2
        with self.assertRaises(ValueError):
            verify(summary, tree, selectors)

    def test_one_real_case_still_passes(self):
        summary, tree, selectors = self.fixture()
        self.assertEqual(verify(summary, tree, selectors)["passedTestCases"], 1)
