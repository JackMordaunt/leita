import unittest
from suite import storyboard_difference


class StoryboardDifferenceTest(unittest.TestCase):
    def test_equal_nested_storyboards(self):
        value = {'events': [{'frame': 45, 'target': [12.5, 30.0]}]}
        self.assertIsNone(storyboard_difference(value, value))
        self.assertEqual(storyboard_difference(
            value, {'events': [{'frame': 45, 'target': [12.5, 31.0]}]}),
            '$.events[0].target[1]: light=30.0, dark=31.0')

    def test_exact_coordinate_difference(self):
        self.assertEqual(storyboard_difference(
            {'events': [{'target': [12.5, 30.0]}]},
            {'events': [{'target': [12.501, 30.0]}]}),
            '$.events[0].target[0]: light=12.5, dark=12.501')

    def test_missing_field_and_list_length(self):
        self.assertEqual(storyboard_difference({'frames': 898}, {}),
                         '$.frames: missing from dark')
        self.assertEqual(storyboard_difference({'events': [1]}, {'events': []}),
                         '$.events.length: light=1, dark=0')


if __name__ == '__main__':
    unittest.main()
