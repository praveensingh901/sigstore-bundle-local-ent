#!/usr/bin/env python3
"""Convert CustomResourceDefinitions to kubeconform JSON schemas.

usage: crd-schemas.py <out-dir> <crd.yaml>...
Writes <out-dir>/<group>/<kind>_<version>.json. Nested objects get
additionalProperties: false (strict), so a misspelt field fails validation;
the root object is left open for apiVersion/kind/metadata.
"""
import copy, json, os, sys
import yaml

def strict(node, root=False):
    if isinstance(node, dict):
        if (not root and node.get("type") == "object" and "properties" in node
                and "additionalProperties" not in node
                and not node.get("x-kubernetes-preserve-unknown-fields")):
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)

def main():
    out, files = sys.argv[1], sys.argv[2:]
    n = 0
    for f in files:
        with open(f) as fh:
            for d in yaml.safe_load_all(fh):
                if not d or d.get("kind") != "CustomResourceDefinition":
                    continue
                group = d["spec"]["group"]
                kind = d["spec"]["names"]["kind"].lower()
                for v in d["spec"]["versions"]:
                    schema = copy.deepcopy(v["schema"]["openAPIV3Schema"])
                    strict(schema, root=True)
                    os.makedirs(os.path.join(out, group), exist_ok=True)
                    with open(os.path.join(out, group, f"{kind}_{v['name']}.json"), "w") as o:
                        json.dump(schema, o)
                    n += 1
    print(f"{n} schemas written to {out}")

if __name__ == "__main__":
    main()
