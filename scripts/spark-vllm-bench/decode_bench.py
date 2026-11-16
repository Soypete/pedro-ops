"""Single-stream decode benchmark for the Spark vLLM endpoint.

Streams a fixed prompt 6 times at max_tokens=400 (after one warm-up) and reports
client-side decode tok/s (completion tokens / time after the first token) and TTFT.
Reasoning tokens count. Override the endpoint with SPARK_URL / SPARK_MODEL.
See README.md in this directory."""
import json, os, time, urllib.request, statistics
URL=os.environ.get("SPARK_URL","http://spark-f5ea:8000/v1/chat/completions"); MODEL=os.environ.get("SPARK_MODEL","nvidia/GLM-5.3-Flash-FP4-Local")
PROMPT="Write a detailed explanation of how a hash map handles collisions, with a Go example. Be thorough."
def run(max_tokens):
    body=json.dumps({"model":MODEL,"messages":[{"role":"user","content":PROMPT}],"max_tokens":max_tokens,"stream":True,"stream_options":{"include_usage":True}}).encode()
    req=urllib.request.Request(URL,body,{"content-type":"application/json"})
    t0=time.time(); first=None; usage=None; chunks=0
    with urllib.request.urlopen(req,timeout=300) as r:
        for line in r:
            line=line.decode().strip()
            if not line.startswith("data:") or line.endswith("[DONE]"): continue
            d=json.loads(line[5:])
            if d.get("usage"): usage=d["usage"]
            ch=d.get("choices") or []
            if ch and (ch[0].get("delta",{}).get("content") or ch[0].get("delta",{}).get("reasoning_content") or ch[0].get("delta",{}).get("reasoning")):
                if first is None: first=time.time()
                chunks+=1
    t1=time.time()
    n=(usage or {}).get("completion_tokens",0)
    return first-t0, n, (n-1)/(t1-first) if first and n>1 else 0, t1-t0
run(64)  # warmup
res=[run(400) for _ in range(6)]
for i,(ttft,n,tps,tot) in enumerate(res,1): print(f"run {i}: ttft {ttft*1000:6.0f} ms | {n:4d} tokens | decode {tps:5.1f} tok/s | total {tot:5.2f}s")
tp=[r[2] for r in res]; print(f"decode tok/s: median {statistics.median(tp):.1f}  min {min(tp):.1f}  max {max(tp):.1f}  | ttft p50 {statistics.median([r[0] for r in res])*1000:.0f} ms")
