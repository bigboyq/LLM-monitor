import XCTest
import Foundation
@testable import LLM_monitor

/// `MinimaxTokenPlanFetcher.parse` 的响应解析规则：业务码映射、空列表、
/// 缺字段容忍与计数字段校验。对应 `MinimaxTokenPlanFetcher`。
final class MinimaxResponseParsingTests: XCTestCase {

    // MARK: - Minimax 响应解析

    func testMinimaxParse() throws {
        let minimaxJson = """
        {
          "model_remains": [
            {
              "start_time": 1783234800000,
              "end_time": 1783252800000,
              "remains_time": 10629565,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "general",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1782662400000,
              "weekly_end_time": 1783267200000,
              "weekly_remains_time": 25029565,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 54,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 64
            }
          ],
          "base_resp": {
            "status_code": 0,
            "status_msg": "success"
          }
        }
        """
        
        let data = minimaxJson.data(using: .utf8)!
        let info = try MinimaxTokenPlanFetcher.parse(data: data)

        XCTAssertEqual(info.models.count, 1)
        XCTAssertEqual(info.models[0].modelName, "general")
        XCTAssertEqual(info.models[0].intervalRemainingPercent, 54.0)
        XCTAssertEqual(info.models[0].weeklyRemainingPercent, 64.0)
    }

    /// base_resp.status_code=1004 应映射为 401，其他非零业务码仍抛 decodingError。
    /// 之前用 JSONSerialization 时这路径是手写 if-else，现在走 JSONDecoder + custom init。
    func testMinimaxParseBaseRespError() {
        let errorJson = """
        {
          "model_remains": [],
          "base_resp": { "status_code": 1004, "status_msg": "login fail: Please carry the API secret key" }
        }
        """
        let data = errorJson.data(using: .utf8)!
        do {
            _ = try MinimaxTokenPlanFetcher.parse(data: data)
            XCTFail("expected QuotaError.httpError, got success")
        } catch let error as QuotaError {
            if case .httpError(let status, let body) = error {
                XCTAssertEqual(status, 401)
                XCTAssertTrue(body.contains("1004") == false, "用户错误文案不应依赖内部业务码: \(body)")
                XCTAssertTrue(body.contains("API Key"))
            } else {
                XCTFail("expected .httpError, got \(error)")
            }
        } catch {
            XCTFail("expected QuotaError, got \(error)")
        }
    }

    /// model_remains 数组为空 → 抛 .decodingError("model_remains 数组为空")。
    /// 即便 base_resp 成功也不行（minimax 返回空 list 说明服务端数据异常）。
    func testMinimaxParseEmptyModelRemains() {
        let emptyJson = """
        {
          "model_remains": [],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let data = emptyJson.data(using: .utf8)!
        do {
            _ = try MinimaxTokenPlanFetcher.parse(data: data)
            XCTFail("expected QuotaError, got success")
        } catch let error as QuotaError {
            if case .decodingError(let msg) = error {
                XCTAssertTrue(msg.contains("model_remains"), "expected msg to mention model_remains, got: \(msg)")
            } else {
                XCTFail("expected .decodingError, got \(error)")
            }
        } catch {
            XCTFail("expected QuotaError, got \(error)")
        }
    }

    /// 单条 record 缺 `model_name` → 这条 record 跳过，其他正常 record 仍能进。
    /// 之前用 JSONSerialization 跟 `guard let modelName = ... else { continue }` 实现，
    /// 现在用 JSONDecoder 的 `init(from:)` 抛 keyNotFound 后由 `compactMap` 过滤。
    func testMinimaxParseRecordMissingModelNameSkipped() throws {
        let mixedJson = """
        {
          "model_remains": [
            {
              "model_name": "general",
              "end_time": 1783252800000,
              "weekly_end_time": 1783267200000,
              "current_interval_remaining_percent": 50,
              "current_weekly_remaining_percent": 60
            },
            {
              "end_time": 1783252800000,
              "current_interval_remaining_percent": 30,
              "current_weekly_remaining_percent": 40
            },
            {
              "model_name": "video",
              "end_time": 1783252800000,
              "weekly_end_time": 1783267200000,
              "current_interval_remaining_percent": 70,
              "current_weekly_remaining_percent": 80
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let data = mixedJson.data(using: .utf8)!
        let info = try MinimaxTokenPlanFetcher.parse(data: data)
        XCTAssertEqual(info.models.count, 2)
        XCTAssertEqual(info.models.map(\.modelName), ["general", "video"])
        XCTAssertEqual(info.models[0].intervalRemainingPercent, 50.0)
        XCTAssertEqual(info.models[1].intervalRemainingPercent, 70.0)
    }

    /// 计数字段的严格 JSON 数字校验（在 `MinimaxModelRemain.init(from:)` 内完成）：
    /// - 小数（1.5）/ 负数 / 布尔 / 字符串 → 抛 decodingError
    /// - 缺失 → 按历史兼容路径视为 0，整体解析成功
    func testMinimaxParseStrictCountValidation() throws {
        func makeData(countField: String, value: String) -> Data {
            """
            {
              "model_remains": [
                {
                  "model_name": "general",
                  "end_time": 1783252800000,
                  "weekly_end_time": 1783267200000,
                  "current_interval_remaining_percent": 50,
                  "current_weekly_remaining_percent": 60,
                  "\(countField)": \(value)
                }
              ],
              "base_resp": { "status_code": 0, "status_msg": "success" }
            }
            """.data(using: .utf8)!
        }

        // 非法值一律拒绝
        for (field, value) in [
            ("current_interval_total_count", "1.5"),
            ("current_interval_total_count", "-3"),
            ("current_interval_total_count", "true"),
            ("current_interval_total_count", "\"12\""),
            ("current_weekly_usage_count", "1e400")
        ] {
            do {
                _ = try MinimaxTokenPlanFetcher.parse(data: makeData(countField: field, value: value))
                XCTFail("expected decodingError for \(field)=\(value)")
            } catch let error as QuotaError {
                guard case .decodingError(let msg) = error,
                      msg.contains("非负整数") else {
                    XCTFail("unexpected error for \(field)=\(value): \(error)")
                    return
                }
            }
        }

        // 整数值合法；字段缺失仍按 0 处理
        let info = try MinimaxTokenPlanFetcher.parse(data: makeData(countField: "current_interval_total_count", value: "120"))
        XCTAssertEqual(info.models.first?.intervalTotalCount, 120)
        let missingJSON = """
        {
          "model_remains": [
            {
              "model_name": "general",
              "end_time": 1783252800000,
              "weekly_end_time": 1783267200000,
              "current_interval_remaining_percent": 50,
              "current_weekly_remaining_percent": 60
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let missing = try MinimaxTokenPlanFetcher.parse(data: missingJSON.data(using: .utf8)!)
        XCTAssertEqual(missing.models.first?.intervalTotalCount, 0)
    }

    /// M1 回归网：周窗口声明 present（status=1）但缺 `weekly_end_time` 时，
    /// 窗口保持 present、reset 透传 nil —— 不按 7 天合成边界伪造 reset 时间
    /// （合成值曾泄漏进 UI 阈值判定与本地分桶）。声明 present 必须给 percent
    /// 的校验保持不变。
    func testMinimaxParseWeeklyWindowMissingEndTimePassesThroughNil() throws {
        let json = """
        {
          "model_remains": [
            {
              "model_name": "general",
              "end_time": 1783252800000,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 54,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 64
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let info = try MinimaxTokenPlanFetcher.parse(data: json.data(using: .utf8)!)
        let model = try XCTUnwrap(info.models.first)
        XCTAssertEqual(model.weeklyStatus, .present)
        XCTAssertEqual(model.weeklyRemainingPercent, 64, "present 周窗口的 percent 透传不受 reset 缺失影响")
        XCTAssertNil(model.weeklyResetsAt, "缺 weekly_end_time 时不合成边界，透传 nil")
        // 消费面契约：present 而 reset 缺失时降级为 nil（固定黄线），无 trap
        XCTAssertNil(model.weeklyTimeRemainingFraction)
    }

    /// M4 回归网：5h 窗口缺 `current_interval_remaining_percent` 且未声明
    /// status（字段子集只有周窗口的 model）时，按 absent 处理、解析继续，
    /// 不再让整份 provider 刷新失败 —— 与周窗口的缺失容忍语义对齐。
    func testMinimaxParseIntervalWindowMissingPercentToleratedAsAbsent() throws {
        let json = """
        {
          "model_remains": [
            {
              "model_name": "video",
              "weekly_end_time": 1783267200000,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 64
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let info = try MinimaxTokenPlanFetcher.parse(data: json.data(using: .utf8)!)
        let model = try XCTUnwrap(info.models.first)
        XCTAssertEqual(model.modelName, "video")
        XCTAssertEqual(model.intervalStatus, .absent)
        XCTAssertEqual(model.intervalRemainingPercent, 0)
        XCTAssertFalse(model.hasIntervalWindow)
        XCTAssertEqual(model.weeklyStatus, .present)
        XCTAssertEqual(model.weeklyRemainingPercent, 64)
        XCTAssertTrue(model.hasWeeklyWindow)
        XCTAssertNotNil(model.weeklyResetsAt)
    }

    /// M4 的另一面：字段声明窗口有效（raw status 1/2）但缺 percent 仍然拒绝，
    /// 5h 与周窗口同一校验强度，不因容忍缺失而放开"声明 present 必须给 percent"。
    func testMinimaxParseDeclaredPresentWindowWithoutPercentStillThrows() throws {
        func makeData(intervalStatus: String?, weeklyStatus: String?) -> Data {
            """
            {
              "model_remains": [
                {
                  "model_name": "general",
                  \(intervalStatus.map { "\"current_interval_status\": \($0)," } ?? "")
                  \(weeklyStatus.map { "\"current_weekly_status\": \($0)," } ?? "")
                  "weekly_end_time": 1783267200000
                }
              ],
              "base_resp": { "status_code": 0, "status_msg": "success" }
            }
            """.data(using: .utf8)!
        }

        // 5h 声明 present（status=1）但缺 percent → 抛 decodingError
        XCTAssertThrowsError(try MinimaxTokenPlanFetcher.parse(data: makeData(intervalStatus: "1", weeklyStatus: nil))) { error in
            guard case let QuotaError.decodingError(message) = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("5h"), "错误消息应提到 5h 窗口，实际：\(message)")
        }
        // 周窗口声明 present 但缺 percent → 同样拒绝
        XCTAssertThrowsError(try MinimaxTokenPlanFetcher.parse(data: makeData(intervalStatus: nil, weeklyStatus: "2"))) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }
}
