#!/usr/bin/env python3
"""A fake `gh` for issues-bin-test.sh: a small in-memory GitHub, persisted in
the JSON file $FAKE_GH_STATE, answering the gh subcommands and GraphQL
operations the issue-verb scripts use.

Every invocation is appended to $FAKE_GH_LOG as one JSON argv array, so a
test can assert which calls were made, or that none was. With
$FAKE_GH_DROP_WRITES=1 every write reports success and changes nothing, which
is how a test drives a script's re-read check.
"""
import base64
import json
import os
import re
import sys

STATE_PATH = os.environ["FAKE_GH_STATE"]


def load():
    with open(STATE_PATH) as f:
        return json.load(f)


def save(state):
    with open(STATE_PATH, "w") as f:
        json.dump(state, f, indent=1)


def fail(message, out=None, code=1):
    if out is not None:
        print(json.dumps(out))
    print("gh: " + message, file=sys.stderr)
    sys.exit(code)


def dropping():
    return os.environ.get("FAKE_GH_DROP_WRITES") == "1"


# ---------------------------------------------------------------------------
# Model helpers.
# ---------------------------------------------------------------------------


def all_issues(state):
    for nwo, repo in state["repos"].items():
        for issue in repo["issues"].values():
            yield nwo, issue


def by_id(state, node_id):
    for nwo, issue in all_issues(state):
        if issue["id"] == node_id:
            return nwo, issue
    return None, None


def by_number(state, nwo, number):
    repo = state["repos"].get(nwo)
    if repo is None:
        return None
    return repo["issues"].get(str(number))


def brief(nwo, issue):
    return {
        "id": issue["id"],
        "number": issue["number"],
        "title": issue["title"],
        "url": "https://github.com/%s/issues/%d" % (nwo, issue["number"]),
        "repository": {"nameWithOwner": nwo},
    }


def render(state, nwo, issue, after=None):
    parent = None
    if issue.get("parent"):
        pnwo, p = by_id(state, issue["parent"])
        parent = brief(pnwo, p)
    children = [brief(n, i) for n, i in all_issues(state) if i.get("parent") == issue["id"]]
    offset = int(after) if after else 0
    page = children[offset:offset + 50]
    has_next = offset + 50 < len(children)
    blocked_by = [brief(*by_id(state, b)) for b in issue.get("blockedBy", [])]
    blocking = [brief(n, i) for n, i in all_issues(state) if issue["id"] in i.get("blockedBy", [])]
    items = []
    for item in issue.get("projectItems", []):
        values = [{"__typename": "ProjectV2ItemFieldTextValue"}]
        for fid, value in item["fields"].items():
            if "number" in value:
                values.append({"__typename": "ProjectV2ItemFieldNumberValue", "field": {"id": fid},
                               "number": value["number"]})
            else:
                values.append({"__typename": "ProjectV2ItemFieldSingleSelectValue", "field": {"id": fid},
                               "name": value["name"], "optionId": value["optionId"]})
        items.append({"id": item["id"], "project": {"id": item["project"]}, "fieldValues": {"nodes": values}})
    issue_fields = [{"__typename": "IssueFieldSingleSelectValue", "name": v["name"], "optionId": v["optionId"],
                     "field": {"id": fid}} for fid, v in issue.get("issueFields", {}).items()]
    issue_type = None
    if issue.get("issueType"):
        issue_type = {"id": issue["issueType"], "name": state["issueTypes"][issue["issueType"]]}
    out = brief(nwo, issue)
    out.update({
        "state": issue.get("state", "OPEN"),
        "body": issue.get("body", ""),
        "labels": {"nodes": [{"name": n} for n in issue.get("labels", [])]},
        "assignees": {"nodes": [{"login": n} for n in issue.get("assignees", [])]},
        "issueType": issue_type,
        "parent": parent,
        "subIssues": {"pageInfo": {"hasNextPage": has_next, "endCursor": str(offset + 50) if has_next else None},
                      "nodes": page},
        "blockedBy": {"nodes": blocked_by},
        "blocking": {"nodes": blocking},
        "projectItems": {"nodes": items},
        "issueFieldValues": {"nodes": issue_fields},
        "viewerCanSetFields": issue.get("viewerCanSetFields", True),
    })
    return out


def new_issue(state, nwo, title, body):
    repo = state["repos"][nwo]
    number = max([int(n) for n in repo["issues"]] + [0]) + 1
    issue = {"id": "I_%s_%d" % (nwo.replace("/", "_"), number), "number": number, "title": title, "body": body,
             "state": "OPEN", "labels": [], "assignees": [], "blockedBy": [], "projectItems": [], "issueFields": {}}
    repo["issues"][str(number)] = issue
    return issue


def apply_labels(state, nwo, issue, add, remove):
    known = [l.lower() for l in state["repos"][nwo].get("validLabels", [])]
    for name in add:
        if name.lower() in known and name.lower() not in [l.lower() for l in issue["labels"]]:
            issue["labels"].append(name)
    issue["labels"] = [l for l in issue["labels"] if l.lower() not in [r.lower() for r in remove]]


def apply_assignees(state, nwo, issue, add, remove):
    known = [a.lower() for a in state["repos"][nwo].get("collaborators", [])]
    for login in add:
        if login.lower() in known and login.lower() not in [a.lower() for a in issue["assignees"]]:
            issue["assignees"].append(login)
    issue["assignees"] = [a for a in issue["assignees"] if a.lower() not in [r.lower() for r in remove]]


def csv(value):
    return [v.strip() for v in value.split(",") if v.strip()]


# ---------------------------------------------------------------------------
# gh api graphql
# ---------------------------------------------------------------------------


def graphql(state, args):
    fields = {}
    i = 0
    while i < len(args):
        if args[i] in ("-f", "-F", "--raw-field", "--field"):
            key, _, value = args[i + 1].partition("=")
            fields[key] = value
            i += 2
        else:
            i += 1
    query = fields.pop("query")
    mutation = query.lstrip().startswith("mutation")

    if not mutation:
        nwo = fields["owner"] + "/" + fields["repo"]
        issue = by_number(state, nwo, fields["number"])
        if issue is None:
            fail("Could not resolve to an Issue with the number of %s." % fields["number"],
                 {"data": {"repository": {"issue": None}},
                  "errors": [{"type": "NOT_FOUND", "message": "Could not resolve to an Issue"}]})
        print(json.dumps({"data": {"repository": {"issue": render(state, nwo, issue, fields.get("after"))}}}))
        return

    name = re.search(r"\{\s*(\w+)\s*\(", query).group(1)

    def node(key):
        nwo, issue = by_id(state, fields[key])
        if issue is None:
            fail("Could not resolve to a node with the global id of '%s'" % fields[key])
        return nwo, issue

    if name == "addProjectV2ItemById":
        _, issue = node("contentId")
        item = {"id": "PVTI_" + issue["id"], "project": fields["projectId"], "fields": {}}
        if not dropping():
            issue["projectItems"].append(item)
        result = {"item": {"id": item["id"]}}
    elif name == "updateProjectV2ItemFieldValue":
        fid = fields["fieldId"]
        if fid not in state["projectFields"]:
            fail("Could not resolve to a node with the global id of '%s'" % fid)
        target = None
        for _, issue in all_issues(state):
            for item in issue["projectItems"]:
                if item["id"] == fields["itemId"]:
                    target = item
        if target is None:
            fail("Could not resolve to a node with the global id of '%s'" % fields["itemId"])
        if "value" in fields:
            value = {"number": float(fields["value"])}
        else:
            value = {"optionId": fields["optionId"], "name": state["projectOptions"][fields["optionId"]]}
        if not dropping():
            target["fields"][fid] = value
        result = {"projectV2Item": {"id": target["id"]}}
    elif name == "setIssueFieldValue":
        _, issue = node("issueId")
        fid = fields["fieldId"]
        if fid not in state["issueFieldIds"]:
            fail("Could not resolve to a node with the global id of '%s'" % fid)
        if not dropping():
            issue["issueFields"][fid] = {"optionId": fields["optionId"],
                                         "name": state["issueFieldOptions"][fields["optionId"]]}
        result = {"issue": {"id": issue["id"]}}
    elif name == "updateIssueIssueType":
        _, issue = node("issueId")
        if not dropping():
            issue["issueType"] = fields["issueTypeId"]
        result = {"issue": {"id": issue["id"]}}
    elif name in ("addSubIssue", "removeSubIssue"):
        _, parent = node("parentId")
        _, child = node("childId")
        if not dropping():
            if name == "addSubIssue":
                child["parent"] = parent["id"]
            elif child.get("parent") == parent["id"]:
                child["parent"] = None
        result = {"issue": {"id": parent["id"]}}
    elif name in ("addBlockedBy", "removeBlockedBy"):
        _, blocked = node("issueId")
        _, blocker = node("blockingIssueId")
        if not dropping():
            if name == "addBlockedBy":
                if blocker["id"] not in blocked["blockedBy"]:
                    blocked["blockedBy"].append(blocker["id"])
            else:
                blocked["blockedBy"] = [b for b in blocked["blockedBy"] if b != blocker["id"]]
        result = {"issue": {"id": blocked["id"]}}
    else:
        fail("fake gh: unknown mutation " + name)
    save(state)
    print(json.dumps({"data": {name: result}}))


# ---------------------------------------------------------------------------
# Other subcommands.
# ---------------------------------------------------------------------------


def opts(args):
    """Split argv into positionals and a dict of --flag values."""
    positional, flags = [], {}
    i = 0
    while i < len(args):
        if args[i].startswith("--"):
            flags[args[i][2:]] = args[i + 1]
            i += 2
        else:
            positional.append(args[i])
            i += 1
    return positional, flags


def main():
    args = sys.argv[1:]
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps(args) + "\n")
    state = load()

    if args[:2] == ["repo", "view"]:
        print(state["current"])
    elif args[:2] == ["api", "user"]:
        print(state["user"])
    elif args[:2] == ["api", "graphql"]:
        graphql(state, args[2:])
    elif args[0] == "api" and "/contents/" in args[1]:
        nwo = "/".join(args[1].split("/")[1:3])
        config = state["repos"].get(nwo, {}).get("config")
        if config is None:
            fail("Not Found (HTTP 404)")
        print(base64.b64encode(config.encode()).decode())
    elif args[0] == "api" and "/issues/comments/" in args[1]:
        comment = state.get("comments", {}).get(args[1].rsplit("/", 1)[1])
        if comment is None:
            fail("Not Found (HTTP 404)")
        print("https://api.github.com/repos/%s/issues/%d" % (comment["repo"], comment["number"]))
    elif args[0] == "issue":
        verb = args[1]
        positional, flags = opts(args[2:])
        nwo = flags.get("repo", state["current"])
        if verb == "create":
            with open(flags["body-file"]) as f:
                body = f.read()
            issue = new_issue(state, nwo, flags["title"], body)
            if not dropping():
                apply_labels(state, nwo, issue, csv(flags.get("label", "")), [])
                apply_assignees(state, nwo, issue, csv(flags.get("assignee", "")), [])
            save(state)
            print("https://github.com/%s/issues/%d" % (nwo, issue["number"]))
            return
        issue = by_number(state, nwo, positional[0])
        if issue is None:
            fail("Could not resolve to an issue or pull request with the number of %s." % positional[0])
        if verb == "edit":
            if not dropping():
                if "title" in flags:
                    issue["title"] = flags["title"]
                if "body-file" in flags:
                    with open(flags["body-file"]) as f:
                        issue["body"] = f.read()
                apply_labels(state, nwo, issue, csv(flags.get("add-label", "")), csv(flags.get("remove-label", "")))
                apply_assignees(state, nwo, issue, csv(flags.get("add-assignee", "")),
                                csv(flags.get("remove-assignee", "")))
            save(state)
            print("https://github.com/%s/issues/%d" % (nwo, issue["number"]))
        elif verb == "comment":
            comments = state.setdefault("comments", {})
            cid = str(1000 + len(comments))
            if "body-file" in flags:
                with open(flags["body-file"]) as f:
                    body = f.read()
            else:
                body = flags["body"]
            if not dropping():
                comments[cid] = {"repo": nwo, "number": issue["number"], "body": body}
            save(state)
            print("https://github.com/%s/issues/%d#issuecomment-%s" % (nwo, issue["number"], cid))
        elif verb == "close":
            if not dropping():
                issue["state"] = "CLOSED"
            save(state)
        else:
            fail("fake gh: unknown issue verb " + verb)
    else:
        fail("fake gh: unsupported call " + " ".join(args))


main()
