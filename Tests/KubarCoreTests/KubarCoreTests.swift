import XCTest
@testable import KubarCore

final class KubarCoreTests: XCTestCase {
    func testSelfChecks() {
        KubeConfigModelsSelfCheck.run()
        ConnectionStatusSelfCheck.run()
        KubectlRunnerSelfCheck.run()
    }

    func testNodeParsing() {
        let json = """
        {"items":[{"metadata":{"name":"n1","labels":{"node-role.kubernetes.io/control-plane":""}},
        "status":{"conditions":[{"type":"Ready","status":"True"}],
        "nodeInfo":{"kubeletVersion":"v1.32.0","osImage":"Ubuntu","containerRuntimeVersion":"containerd://2.0"},
        "capacity":{"cpu":"2","memory":"4194304Ki"}}},
        {"metadata":{"name":"n2"},"status":{"nodeInfo":{"kubeletVersion":"","osImage":"","containerRuntimeVersion":""}}}]}
        """
        let usage = ["n1": NodeInfo.Usage(cpu: "84m", cpuPct: 8, mem: "1175Mi", memPct: 41)]
        let nodes = NodeInfo.parse(json, usage: usage)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(nodes[0].ready)
        XCTAssertEqual(nodes[0].roles, "control-plane")
        XCTAssertEqual(nodes[0].capacity, "2 CPU · 4.0 GiB")
        XCTAssertEqual(nodes[0].usage?.cpuPct, 8)
        XCTAssertFalse(nodes[1].ready)
        XCTAssertEqual(nodes[1].roles, "<none>")
        XCTAssertNil(nodes[1].usage)
        XCTAssertTrue(NodeInfo.parse("garbage", usage: [:]).isEmpty)
    }

    func testDeploymentParsing() {
        let json = """
        {"items":[{"metadata":{"name":"api"},"spec":{"replicas":3,"selector":{"matchLabels":{"b":"2","a":"1"}}},"status":{"readyReplicas":2}},
        {"metadata":{"name":"idle"},"spec":{"selector":{"matchLabels":{"app":"idle"}}},"status":{}}]}
        """
        let deployments = DeploymentInfo.parse(json)
        XCTAssertEqual(deployments.map(\.name), ["api", "idle"])
        XCTAssertEqual(deployments[0].selector, "a=1,b=2")
        XCTAssertEqual(deployments[0].ready, 2)
        XCTAssertEqual(deployments[0].desired, 3)
        XCTAssertEqual(deployments[1].ready, 0)
        XCTAssertEqual(deployments[1].desired, 1)
    }

    func testPodParsing() {
        let json = """
        {"items":[
        {"metadata":{"name":"ok"},"spec":{"nodeName":"n1"},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":1,"state":{}}]}},
        {"metadata":{"name":"crash"},"spec":{"nodeName":"n1"},"status":{"phase":"Running","containerStatuses":[{"ready":false,"restartCount":5,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}},
        {"metadata":{"name":"gone","deletionTimestamp":"2026-10-02T00:00:00Z"},"spec":{},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":0,"state":{}}]}}]}
        """
        let pods = PodInfo.parse(json)
        XCTAssertEqual(pods.count, 3)
        XCTAssertTrue(pods[0].ok)
        XCTAssertEqual(pods[0].ready, "1/1")
        XCTAssertEqual(pods[0].restarts, 1)
        XCTAssertFalse(pods[1].ok)
        XCTAssertEqual(pods[1].status, "CrashLoopBackOff")
        XCTAssertEqual(pods[2].status, "Terminating")
        XCTAssertEqual(pods[2].node, "unscheduled")
    }

    func testConnectionHints() {
        let gcloud = "cred.go:166] print credential failed ... Reauthentication failed. cannot prompt during non-interactive execution.\nPlease run:\n\n  $ gcloud auth login"
        XCTAssertEqual(ConnectionHint.suggest(for: gcloud)?.command, "gcloud auth login")
        XCTAssertEqual(ConnectionHint.suggest(for: "getting credentials: exec: executable gke-gcloud-auth-plugin not found")?.command,
                       "gcloud components install gke-gcloud-auth-plugin")
        XCTAssertNotNil(ConnectionHint.suggest(for: "kubectl not found")?.command)
        XCTAssertNil(ConnectionHint.suggest(for: "Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout")?.command)
        XCTAssertNotNil(ConnectionHint.suggest(for: "Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout"))
        XCTAssertNotNil(ConnectionHint.suggest(for: "error: You must be logged in to the server (Unauthorized)"))
        XCTAssertNil(ConnectionHint.suggest(for: "something unrelated"))
    }
}
