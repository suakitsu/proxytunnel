package main

import "testing"

func TestParseGenericCandidateSource(t *testing.T) {
	data := []byte(`[{"proxy":"http://8.8.8.8:8080","protocol":"http","ip":"8.8.8.8","port":8080,"country":"US","country_cn":"美国","country_emoji":"🇺🇸","city":"Example","asn":"15169","asOrganization":"Example Network"}]`)
	nodes, err := parseCandidateSource("http", data)
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 1 || nodes[0].CountryCode != "US" || nodes[0].ID == "" {
		t.Fatalf("unexpected parsed candidate: %#v", nodes)
	}
}

func TestParseProxyIPRequiresPort443(t *testing.T) {
	data := []byte(`{"data":[{"ip":"1.1.1.1","port":[443],"meta":{"country":"AU","country_cn":"澳大利亚"}},{"ip":"8.8.8.8","port":[80],"meta":{"country":"US"}}]}`)
	nodes, err := parseCandidateSource("proxyip", data)
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 1 || nodes[0].IP != "1.1.1.1" {
		t.Fatalf("unexpected ProxyIP candidates: %#v", nodes)
	}
}

func TestCandidatePublicIPGuard(t *testing.T) {
	for _, private := range []string{"127.0.0.1", "10.0.0.1", "192.168.1.1", "::1"} {
		if isPublicIP(private) {
			t.Fatalf("private address %s was accepted", private)
		}
	}
	if !isPublicIP("1.1.1.1") {
		t.Fatal("public address was rejected")
	}
}
