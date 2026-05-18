import json
import sys

def analyze(data_file):
    with open(data_file) as f:
        data = json.load(f)

    total = sum(item['value'] for item in data)
    average = total / len(data)

    return {"total": total, "average": average, "count": len(data)}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python analyze.py <data.json>")
        sys.exit(1)
    result = analyze(sys.argv[1])
    print(json.dumps(result, indent=2))
