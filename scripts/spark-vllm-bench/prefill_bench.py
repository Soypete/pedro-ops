"""Prefill throughput benchmark for the Spark vLLM endpoint.

Sends unique random prompts (so the prefix cache cannot help) at four sizes,
max_tokens=8, two runs each, and reports prompt_tokens / TTFT as prefill tok/s.
Override the endpoint with SPARK_URL / SPARK_MODEL. See README.md in this directory."""
import json, os, time, urllib.request, random, statistics
URL=os.environ.get("SPARK_URL","http://spark-f5ea:8000/v1/chat/completions"); MODEL=os.environ.get("SPARK_MODEL","nvidia/GLM-5.3-Flash-FP4-Local")
words=[w for w in "the system policy request token agent runtime cluster memory kernel model cache stream buffer network storage service config deploy release review audit tenant identity group access gateway proxy manifest decision allow deny".split()]
def run(target_words):
    rnd=random.Random(time.time_ns())
    text=" ".join(rnd.choice(words)+str(rnd.randint(0,9999)) for _ in range(target_words))  # unique, defeats prefix cache
    body=json.dumps({"model":MODEL,"messages":[{"role":"user","content":"Summarize in one sentence: "+text}],"max_tokens":8,"stream":True,"stream_options":{"include_usage":True}}).encode()
    req=urllib.request.Request(URL,body,{"content-type":"application/json"})
    t0=time.time(); first=None; usage=None
    with urllib.request.urlopen(req,timeout=600) as r:
        for line in r:
            line=line.decode().strip()
            if not line.startswith("data:") or line.endswith("[DONE]"): continue
            d=json.loads(line[5:])
            if d.get("usage"): usage=d["usage"]
            ch=d.get("choices") or []
            if ch and first is None and ch[0].get("delta",{}).get("content") is not None or (ch and first is None and (ch[0].get("delta",{}).get("reasoning") or ch[0].get("delta",{}).get("reasoning_content"))):
                first=time.time()
    n=usage["prompt_tokens"]; ttft=first-t0
    return n, ttft, n/ttft
run(200)  # warmup
for w in (800, 2500, 6000, 12000):
    rs=[run(w) for _ in range(2)]
    print(f"~{rs[0][0]:6d} prompt tokens: ttft {statistics.mean(r[1] for r in rs):6.2f}s  prefill {statistics.mean(r[2] for r in rs):7.0f} tok/s")
