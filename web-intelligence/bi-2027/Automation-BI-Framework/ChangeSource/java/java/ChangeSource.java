// ============================================================================
//  ChangeSource.java - Bulk/Single Webi "Change Source" WITHOUT Bruno
// ----------------------------------------------------------------------------
//  Mirrors the Bruno "00 - Bulk Change Source (All-in-One)" flow:
//    logon -> per doc: open -> list dataproviders -> compute mapping
//             (04a default GET / 04a2 GET+strategies) -> apply (04b POST)
//             -> save (empty PUT) -> close -> logoff.
//
//  Config is READ FROM environments/my-env.bru (same single source of truth
//  Bruno uses).  Pure JDK - NO external / SAP BOE jars required (it talks to
//  the BI RESTful SDK over plain HTTP, exactly like Bruno). Runs on any JRE.
//
//  IMPORTANT: this talks to the SAME server as the Bruno collection and reads
//  the SAME environments/my-env.bru file. Keep the .java / .jar INSIDE the
//  extracted Bruno collection folder (the folder that contains
//  environments/my-env.bru), or pass --env with a full path.
//
//  BUILD (JDK 9+):
//     javac -d out java/ChangeSource.java
//     jar --create --file change_source.jar --main-class ChangeSource -C out .
//  BUILD (JDK 8):
//     javac -d out java/ChangeSource.java
//     jar cfe change_source.jar ChangeSource -C out .
//  RUN AS JAR:
//     java -jar change_source.jar
//     java -jar change_source.jar --docIds 5418,5403 --strategyMode custom --test
//     java -jar change_source.jar --env environments/my-env.bru
//  RUN WITHOUT MAKING A JAR (compile + run the .java directly):
//     javac -d out java/ChangeSource.java
//     java  -cp out ChangeSource --test
// ============================================================================

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

public class ChangeSource {

    // ------- tiny HTTP result holder -------
    static class Resp {
        boolean ok; int status; String body; Map<String,List<String>> headers;
        Resp(boolean ok,int status,String body,Map<String,List<String>> h){this.ok=ok;this.status=status;this.body=body;this.headers=h;}
    }

    static String REST;
    static String token = null;

    public static void main(String[] args) throws Exception {
        Map<String,String> cli = parseArgs(args);

        String envFile = cli.containsKey("env") ? cli.get("env") : resolveEnvFile();
        Map<String,String> cfg = readBruVars(envFile);

        String baseUrl = stripTrailingSlashes(cfg.getOrDefault("baseUrl",""));
        String cms      = cfg.getOrDefault("cms","");
        String user     = cfg.getOrDefault("user","");
        String password = cfg.getOrDefault("password","");
        String auth     = cfg.getOrDefault("auth","secEnterprise");
        String target   = cli.containsKey("targetuniverse") ? cli.get("targetuniverse")
                            : cfg.getOrDefault("targetuniverse","");
        String runnerAction = cli.containsKey("test") ? "test"
                            : cfg.getOrDefault("runnerAction","change");
        boolean dryRun = "test".equalsIgnoreCase(runnerAction.trim());
        String mode = cli.containsKey("strategyMode") ? cli.get("strategyMode")
                            : cfg.getOrDefault("strategyMode","default");
        boolean useCustom = "custom".equalsIgnoreCase(mode.trim());
        String docIdsRaw = cli.containsKey("docIds") ? cli.get("docIds")
                            : cfg.getOrDefault("docIds","");

        REST = baseUrl + "/biprws";

        // doc ids: split on comma/space/semicolon, drop blanks, de-dupe (keep order)
        LinkedHashSet<String> ids = new LinkedHashSet<>();
        for (String s : docIdsRaw.split("[,;\\s]+")) { s=s.trim(); if(!s.isEmpty()) ids.add(s); }
        List<String> docIds = new ArrayList<>(ids);

        // strategies body (custom mode). Only use mappingStrategies from the env
        // file if it actually looks like a JSON object; otherwise fall back to the
        // built-in safe default (Removal disabled) - mirrors the PowerShell runner.
        String strategiesBody = null;
        if (useCustom) {
            String ms = cfg.getOrDefault("mappingStrategies","").trim();
            if (ms.startsWith("{") && ms.endsWith("}")) {
                strategiesBody = ms;                       // valid-looking JSON string
            } else {
                if (!ms.isEmpty())
                    System.out.println("  [STRATEGY] 'mappingStrategies' is not JSON ('" + ms + "') - using built-in default.");
                strategiesBody = defaultStrategiesJson();
            }
        }

        String line = repeat("=",60);
        System.out.println(line);
        System.out.println("BULK CHANGE SOURCE (Java)  |  mode = " + (dryRun?"DRY RUN (test)":"CHANGE") + "  |  target universe = " + target);
        System.out.println("Strategy: " + (useCustom?"CUSTOM (declared strategies)":"DEFAULT (regular mapping)"));
        System.out.println("REST root: " + REST);
        System.out.println("Config file: " + envFile);
        System.out.println("Documents to process: " + String.join(", ", docIds) + "  (count=" + docIds.size() + ")");
        System.out.println(line);

        if (docIds.isEmpty()) { System.out.println("ABORT: docIds is empty (my-env.bru or --docIds)."); return; }
        if (target.isEmpty())  { System.out.println("ABORT: targetuniverse is empty."); return; }

        // Logon
        String logonBody = "{\"userName\":"+jstr(user)+",\"password\":"+jstr(password)+",\"auth\":"+jstr(auth)+",\"cms\":"+jstr(cms)+"}";
        Resp logon = api("POST","/logon/long", logonBody);
        if (!logon.ok) { System.out.println("ABORT: logon failed status="+logon.status+" (response body omitted for security)"); return; }
        token = headerValue(logon.headers, "X-SAP-LogonToken");
        if (token == null) token = extract(logon.body, "logonToken");
        if (token != null) token = token.replaceAll("^\"|\"$","").trim();
        if (token == null || token.isEmpty()) {
            System.out.println("ABORT: no logon token returned.");
            // Logon call succeeded (HTTP 2xx) but no token in response - logoff to clean up the server session.
            api("POST","/logoff", null);
            return;
        }
        System.out.println("[LOGON] ok");

        List<String[]> summary = new ArrayList<>();

        try {
        for (String docId : docIds) {
            System.out.println();
            System.out.println("---- DOC " + docId + " ----");
            int queries=0, changed=0, skipped=0, failed=0; String status="OK";

            // Open
            Resp open = api("GET","/raylight/v1/documents/"+docId, null);
            if (!open.ok) {
                if (open.status==404){ System.out.println("  [OPEN] NOT FOUND - docId "+docId+" does not exist (HTTP 404). Check docIds in my-env.bru."); status="NOT_FOUND"; }
                else if (open.status==401||open.status==403){ System.out.println("  [OPEN] NOT AUTHORIZED for docId "+docId+" (HTTP "+open.status+")."); status="NOT_AUTHORIZED"; }
                else {
                    System.out.println("  [OPEN] FAILED for docId "+docId+" status="+open.status+" :: "+open.body);
                    status="OPEN_FAILED";
                    // The server may have partially opened a document session; close it to
                    // avoid leaking an open occurrence (mirrors the Bruno JS finally block).
                    closeDoc(docId);
                }
                summary.add(new String[]{docId,status,""+queries,""+changed,""+skipped,""+failed});
                continue;
            }
            String docName = extract(open.body, "name"); if (docName==null) docName=docId;
            System.out.println("  [OPEN] ok - \"" + docName + "\"");

            // List data providers
            Resp dpResp = api("GET","/raylight/v1/documents/"+docId+"/dataproviders", null);
            if (!dpResp.ok) {
                System.out.println("  [DATAPROVIDERS] FAILED status="+dpResp.status+" :: "+dpResp.body);
                status="DP_LIST_FAILED";
                summary.add(new String[]{docId,status,""+queries,""+changed,""+skipped,""+failed});
                closeDoc(docId);
                continue;
            }
            List<String[]> providers = parseProviders(dpResp.body);  // each = {id,name}
            queries = providers.size();
            System.out.println("  [DATAPROVIDERS] found " + queries + " query(ies)");

            for (String[] dp : providers) {
                String dpId = dp[0];
                String dpName = (dp[1]!=null && !dp[1].isEmpty()) ? dp[1] : dpId;

                String mapPath = "/raylight/v1/documents/"+docId+"/dataproviders/mappings"
                        + "?originDataproviderIds=" + enc(dpId)
                        + "&targetDatasourceId=" + enc(target)
                        + "&skipChecking=false";

                String viaReq = useCustom ? "04a2 (GET + strategies)" : "04a (plain GET)";
                System.out.println("    - [MAP] query \""+dpName+"\" ("+dpId+"): computing mapping via "+viaReq+" ...");
                Resp mapCompute = api("GET", mapPath, strategiesBody);   // body null in default mode
                String mapMode = useCustom ? "custom" : "default";
                if (!mapCompute.ok && useCustom) {
                    System.out.println("    - [MAP] 04a2 (GET + strategies) failed (status "+mapCompute.status+") - falling back to 04a (plain GET).");
                    mapCompute = api("GET", mapPath, null);
                    mapMode = "default(fallback)"; viaReq = "04a (plain GET, fallback)";
                }
                if (!mapCompute.ok) {
                    failed++;
                    System.out.println("    - [MAP:"+mapMode+"] via "+viaReq+" - query \""+dpName+"\" ("+dpId+"): FAILED status="+mapCompute.status+" :: "+mapCompute.body);
                    continue;
                }

                int total = countOccurrences(mapCompute.body, "\"@status\"");
                int notOk = countNotOk(mapCompute.body);
                System.out.println("    - [MAP:"+mapMode+"] query \""+dpName+"\" ("+dpId+"): "+total+" object mapping(s), "+notOk+" not-Ok");

                if (dryRun) {
                    System.out.println("    - [DRYRUN] query \""+dpName+"\" ("+dpId+"): would change source -> "+target+" (mapping computed, apply skipped)");
                    skipped++;
                    continue;
                }

                // APPLY (04b): POST the exact computed mapping payload back
                System.out.println("    - [APPLY] query \""+dpName+"\" ("+dpId+"): applying mapping via 04b (POST mapping) ...");
                Resp mapPost = api("POST", mapPath, mapCompute.body);
                if (mapPost.ok) {
                    changed++;
                    System.out.println("    - [CHANGE] query \""+dpName+"\" ("+dpId+"): source -> universe "+target+"  OK via 04b (status "+mapPost.status+")");
                } else {
                    failed++;
                    System.out.println("    - [CHANGE] query \""+dpName+"\" ("+dpId+"): FAILED via 04b status="+mapPost.status+" :: "+mapPost.body);
                }
            }

            // Save (empty-body PUT)
            if (dryRun) {
                System.out.println("  [SAVE] n/a - dry run");
            } else if (changed > 0) {
                Resp save = api("PUT","/raylight/v1/documents/"+docId, null);
                if (save.ok) System.out.println("  [SAVE] saved in place - PUT documents/"+docId+" (status "+save.status+")");
                else { status="SAVE_FAILED"; System.out.println("  [SAVE] FAILED status="+save.status+" :: "+save.body); }
            } else {
                System.out.println("  [SAVE] nothing changed");
            }

            // Close
            closeDoc(docId);
            summary.add(new String[]{docId,status,""+queries,""+changed,""+skipped,""+failed});
        }

        // SUMMARY
        System.out.println();
        System.out.println(line);
        System.out.println("SUMMARY");
        System.out.println(line);
        for (String[] s : summary) {
            System.out.println("  Doc "+s[0]+": status="+s[1]+", queries="+s[2]+", changed="+s[3]+", skipped="+s[4]+", failed="+s[5]);
        }
        System.out.println(line);

        } finally {
            if (token != null && !token.isEmpty()) {
                Resp off = api("POST","/logoff", null);
                System.out.println("[LOGOFF] status " + off.status);
            }
            System.out.println("Done.");
        }
    }

    // ---------------- HTTP ----------------
    static Resp api(String method, String path, String body) {
        HttpURLConnection c = null;
        try {
            URL url = new URL(REST + path);
            c = (HttpURLConnection) url.openConnection();
            c.setRequestMethod(method);
            c.setConnectTimeout(60000);
            c.setReadTimeout(120000);
            c.setRequestProperty("Accept", "application/json");
            c.setRequestProperty("Content-Type", "application/json");
            if (token != null) c.setRequestProperty("X-SAP-LogonToken", token);
            if (body != null) {
                c.setDoOutput(true);
                byte[] b = body.getBytes(StandardCharsets.UTF_8);
                try (OutputStream os = c.getOutputStream()) { os.write(b); }
            }
            int status = c.getResponseCode();
            String resp = readStream((status>=200 && status<400) ? c.getInputStream() : c.getErrorStream());
            return new Resp(status>=200 && status<300, status, resp, c.getHeaderFields());
        } catch (Exception e) {
            return new Resp(false, 0, (e.getMessage()==null? e.toString() : e.getMessage()), null);
        } finally {
            if (c != null) c.disconnect();
        }
    }

    static void closeDoc(String docId) {
        Resp close = api("PUT","/raylight/v1/documents/"+docId+"/occurrences/0",
                "{\"occurrence\":{\"state\":{\"$\":\"Unused\"}}}");
        System.out.println("  [CLOSE] occurrences/0 -> Unused (status "+close.status+")");
    }

    static String readStream(InputStream in) throws IOException {
        if (in == null) return "";
        try (InputStream is = in) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192]; int n;
            while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    // ---------------- config / parsing ----------------
    static Map<String,String> parseArgs(String[] args) {
        Map<String,String> m = new HashMap<>();
        for (int i=0;i<args.length;i++) {
            String a = args[i];
            if (a.startsWith("--")) {
                String key = a.substring(2);
                if (key.equals("test")) { m.put("test","true"); }
                else if (i+1 < args.length && !args[i+1].startsWith("--")) { m.put(key, args[++i]); }
                else { m.put(key, "true"); }
            }
        }
        return m;
    }

    // Locate environments/my-env.bru whether we run from the collection folder,
    // from java/, or via double-clicking the jar from somewhere else. Checks the
    // current directory first, then the folder that actually contains the jar /
    // .class file (and its parent, so a jar under java/ still finds it).
    static String resolveEnvFile() {
        String rel = "environments/my-env.bru";
        List<Path> candidates = new ArrayList<>();
        candidates.add(Paths.get(rel));                    // current working dir
        try {
            Path self = Paths.get(ChangeSource.class.getProtectionDomain()
                          .getCodeSource().getLocation().toURI());
            Path dir = Files.isDirectory(self) ? self : self.getParent();
            if (dir != null) {
                candidates.add(dir.resolve(rel));          // next to jar/classes
                if (dir.getParent() != null)
                    candidates.add(dir.getParent().resolve(rel)); // parent (jar in java/)
            }
        } catch (Exception ignore) { }
        for (Path c : candidates) {
            if (c != null && Files.exists(c)) return c.toString();
        }
        return rel;   // fall through -> readBruVars throws a clear "not found"
    }

    static Map<String,String> readBruVars(String path) throws IOException {
        Map<String,String> vars = new LinkedHashMap<>();
        Path p = Paths.get(path);
        if (!Files.exists(p)) throw new FileNotFoundException("Env file not found: " + path);
        boolean inVars = false;
        for (String raw : Files.readAllLines(p, StandardCharsets.UTF_8)) {
            String lineT = raw.trim();
            if (lineT.matches("^vars\\s*\\{.*")) { inVars = true; continue; }
            if (inVars && lineT.equals("}")) break;
            if (inVars && !lineT.isEmpty() && !lineT.startsWith("//")) {
                int idx = lineT.indexOf(':');
                if (idx > 0) {
                    String key = lineT.substring(0, idx).trim();
                    String val = lineT.substring(idx+1).trim();
                    vars.put(key, val);
                }
            }
        }
        return vars;
    }

    static String defaultStrategiesJson() {
        return "{\"strategies\":{\"strategy\":["
             + "{\"name\":\"SamePath\",\"enabled\":true},"
             + "{\"name\":\"SameTechnicalName\",\"enabled\":true},"
             + "{\"name\":\"SameName\",\"enabled\":true},"
             + "{\"name\":\"Removal\",\"enabled\":false}"
             + "]}}";
    }

    // Parse dataproviders response -> list of {id, name}. Handles array or single object.
    static List<String[]> parseProviders(String body) {
        List<String[]> out = new ArrayList<>();
        if (body == null) return out;
        int dpRoot = body.indexOf("\"dataprovider\"");
        if (dpRoot < 0) return out;

        int segmentStart = body.indexOf('[', dpRoot);
        int segmentEnd;
        if (segmentStart >= 0) {
            segmentEnd = findMatchingBracket(body, segmentStart, '[', ']');
            if (segmentEnd < 0) return out;
        } else {
            segmentStart = body.indexOf('{', dpRoot);
            if (segmentStart < 0) return out;
            segmentEnd = findMatchingBracket(body, segmentStart, '{', '}');
            if (segmentEnd < 0) return out;
        }

        String segment = body.substring(segmentStart, segmentEnd + 1);
        // Scan only dataprovider segment, not the whole response body.
        int i = 0;
        while (true) {
            int idPos = segment.indexOf("\"id\"", i);
            if (idPos < 0) break;
            String id = readJsonStringValueAfter(segment, idPos + 4);
            // look for a "name" within the next ~200 chars for a friendly label
            String name = null;
            int namePos = segment.indexOf("\"name\"", idPos);
            if (namePos >= 0 && namePos - idPos < 400) {
                name = readJsonStringValueAfter(segment, namePos + 6);
            }
            // Accept any non-empty dataprovider id; warn if it doesn't match the
            // typical DP\d+ pattern so the user is informed rather than silently
            // skipped (some server versions may use different id formats).
            if (id != null && !id.isEmpty()) {
                if (!id.matches("DP\\d+"))
                    System.out.println("  [WARN] Unexpected dataprovider id format: \"" + id + "\" - including anyway.");
                out.add(new String[]{id, name});
            }
            i = idPos + 4;
        }
        // de-dupe by id preserving order
        LinkedHashMap<String,String[]> uniq = new LinkedHashMap<>();
        for (String[] p : out) if (!uniq.containsKey(p[0])) uniq.put(p[0], p);
        return new ArrayList<>(uniq.values());
    }

    // returns the string value of the first JSON token after position (expects  : "value")
    static String readJsonStringValueAfter(String s, int from) {
        int i = from;
        while (i < s.length() && s.charAt(i) != ':' ) { if (s.charAt(i)=='}'||s.charAt(i)==',') return null; i++; }
        i++; // skip ':'
        while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        if (i >= s.length() || s.charAt(i) != '"') return null;
        i++; // opening quote
        StringBuilder sb = new StringBuilder();
        while (i < s.length()) {
            char ch = s.charAt(i);
            if (ch == '\\' && i+1 < s.length()) {
                char next = s.charAt(i+1);
                if (next == 'u' && i+5 < s.length()) {
                    try {
                        int cp = Integer.parseInt(s.substring(i+2, i+6), 16);
                        sb.append((char) cp);
                    } catch (NumberFormatException ignored) {
                        sb.append(next);
                    }
                    i += 6;
                } else {
                    switch (next) {
                        case 'n': sb.append('\n'); break;
                        case 'r': sb.append('\r'); break;
                        case 't': sb.append('\t'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        default: sb.append(next); break;
                    }
                    i += 2;
                }
                continue;
            }
            if (ch == '"') break;
            sb.append(ch); i++;
        }
        return sb.toString();
    }

    static int findMatchingBracket(String s, int start, char open, char close) {
        int depth = 0;
        for (int i = start; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch == open) depth++;
            else if (ch == close) {
                depth--;
                if (depth == 0) return i;
            }
        }
        return -1;
    }

    static String extract(String body, String key) {
        if (body == null) return null;
        int k = body.indexOf("\""+key+"\"");
        if (k < 0) return null;
        return readJsonStringValueAfter(body, k + key.length() + 2);
    }

    static int countOccurrences(String s, String sub) {
        if (s == null) return 0;
        int count=0, idx=0;
        while ((idx = s.indexOf(sub, idx)) != -1) { count++; idx += sub.length(); }
        return count;
    }

    // count mappings whose @status is not "Ok"
    static int countNotOk(String body) {
        if (body == null) return 0;
        int count=0, idx=0;
        String key = "\"@status\"";
        while ((idx = body.indexOf(key, idx)) != -1) {
            String v = readJsonStringValueAfter(body, idx + key.length());
            if (v != null && !v.equalsIgnoreCase("ok")) count++;
            idx += key.length();
        }
        return count;
    }

    // ---------------- misc utils ----------------
    static String headerValue(Map<String,List<String>> headers, String name) {
        if (headers == null) return null;
        for (Map.Entry<String,List<String>> e : headers.entrySet()) {
            if (e.getKey()!=null && e.getKey().equalsIgnoreCase(name)) {
                List<String> v = e.getValue();
                if (v != null && !v.isEmpty()) return v.get(0);
            }
        }
        return null;
    }

    static String enc(String s) {
        try { return URLEncoder.encode(s, "UTF-8"); } catch (Exception e) { return s; }
    }

    static String jstr(String s) {
        if (s == null) return "\"\"";
        StringBuilder sb = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default: sb.append(c);
            }
        }
        sb.append("\"");
        return sb.toString();
    }

    static String stripTrailingSlashes(String s) {
        if (s == null) return "";
        while (s.endsWith("/")) s = s.substring(0, s.length() - 1);
        return s;
    }

    static String repeat(String s, int n) {
        StringBuilder sb = new StringBuilder();
        for (int i=0;i<n;i++) sb.append(s);
        return sb.toString();
    }
}
