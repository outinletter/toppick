import json
import contextlib
import io
import unittest
from unittest.mock import Mock, patch

import pandas as pd

from collect_pykrx import collect, number
import collect_pykrx


class CollectionTests(unittest.TestCase):
    def test_session_initialization_failure_is_unavailable_json(self):
        output = io.StringIO()
        with patch.object(collect_pykrx, 'load_krx_credentials'), patch.object(collect_pykrx, 'initialize_krx', side_effect=ValueError('private-details')), patch.dict('os.environ', {'KRX_ID':'test','KRX_PW':'test'}), patch('sys.argv',['collector','--codes','005930']), contextlib.redirect_stdout(output):
            collect_pykrx.main()
        result=json.loads(output.getvalue())
        self.assertFalse(result['available'])
        self.assertEqual(result['authenticationStatus'],'unavailable')
        self.assertEqual(result['items'],{})
        self.assertNotIn('private-details',output.getvalue())

    def source(self, count=60):
        index = pd.bdate_range(end="2026-09-18", periods=count)
        frame = pd.DataFrame({"외국인": 10., "금융투자": 1., "보험": 1., "투신": 1.,
                              "사모": 1., "은행": 1., "기타금융": 1., "연기금등": 1.}, index=index)
        api = Mock()
        api.get_market_trading_value_by_date.return_value = frame
        api.get_shorting_volume_by_date.return_value = pd.DataFrame()
        api.get_shorting_balance_by_date.return_value = pd.DataFrame()
        return api, frame

    def test_signed_flow_units_dates_and_institution_components(self):
        api, frame = self.source()
        frame["외국인"] = -10.
        result = collect(api, "005930", "20260101", "20260918")
        self.assertTrue(result["available"])
        self.assertEqual(result["foreign20"], -200)
        self.assertEqual(result["institution20"], 140)
        self.assertEqual(result["flowAsOf"], "2026-09-18")
        self.assertEqual(result["flowUnit"], "KRW")

    def test_optional_failure_preserves_flow(self):
        api, _ = self.source()
        api.get_shorting_volume_by_date.side_effect = TimeoutError()
        result = collect(api, "005930", "20260101", "20260918")
        self.assertTrue(result["available"])
        self.assertEqual(result["sourceStatus"]["shorting"], "TimeoutError")
        self.assertFalse(result["securitiesLendingAvailable"])

    def test_short_history_is_not_a_sixty_day_factor(self):
        api, _ = self.source(20)
        result = collect(api, "005930", "20260101", "20260918")
        self.assertFalse(result["available"])
        self.assertIsNone(result["foreign60"])

    def test_missing_values_do_not_turn_into_neutral_flow(self):
        api, frame = self.source()
        frame.iloc[-1, 0] = float("nan")
        result = collect(api, "005930", "20260101", "20260918")
        self.assertFalse(result["available"])
        self.assertIsNone(result["foreign5"])
        self.assertEqual(result["foreignStreak"], 0)
        json.dumps(result, allow_nan=False)
        self.assertIsNone(number(float("inf")))

    def test_missing_institution_component_is_not_a_total(self):
        api, frame = self.source()
        api.get_market_trading_value_by_date.return_value = frame.drop(columns=["보험"])
        result = collect(api, "005930", "20260101", "20260918")
        self.assertFalse(result["available"])
        self.assertIsNone(result["institution20"])

    def test_dates_are_sorted_and_future_rows_removed(self):
        api, frame = self.source(61)
        api.get_market_trading_value_by_date.return_value = frame.iloc[::-1]
        result = collect(api, "005930", "20260101", "20260917")
        self.assertTrue(result["available"])
        self.assertEqual(result["flowAsOf"], "2026-09-17")
        self.assertEqual(result["flowRows"], 60)

    def test_duplicate_dates_rejected(self):
        api, frame = self.source()
        api.get_market_trading_value_by_date.return_value = pd.concat([frame, frame.iloc[-1:]])
        with self.assertRaises(ValueError):
            collect(api, "005930", "20260101", "20260918")


if __name__ == "__main__":
    unittest.main()
