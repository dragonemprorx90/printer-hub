# Find models (built in 1.22.0)

Files → globe button: search a model site, then print a file already made for
this printer, or slice a model on the home bridge.

## Sources (`lib/models_page.dart`)

| Site | How the app reaches it | Account |
|---|---|---|
| Printables | Public GraphQL API (`api.printables.com/graphql/`): `searchPrints2`, `print { stls gcodes { printer } }`, `getDownloadLink` | None |
| Creality Cloud | `api/cxy/smart_search/v1/model` (search), `v3/model/3mfList` (3MFs per printer), `v3/model/3mfDownload` (download) | Downloads only. Sign in once on Creality's own page in a web view; the app reads the `model_token` and `model_user_id` cookies and sends them as `__CXY_TOKEN_` / `__CXY_UID_`. |
| Thingiverse | REST API (`api.thingiverse.com`) with a bearer token | Free app token from thingiverse.com/developers |
| MakerWorld | Its own website in a web view: it turns away app requests (Cloudflare 403) and has no public API, so the app catches `.3mf/.stl/.step/.obj` downloads instead | Sign in on the site |

Every request identifies itself as `PrinterHub/<version>`. Printables' firewall
turns away Dart's default user agent. API calls time out after 20 s and
downloads after 5 min.

## Ready vs. slice

`printerMatches()` compares the site's printer name with this printer
("K2 Plus" or "Snapmaker U1").

- A matching **G-code** file is uploaded as it is.
- A matching **3MF** is checked for sliced plates (`platesIn3mf`). If it has
  them, the first plate's G-code is uploaded. If not, it goes to the slicer.
- Everything else (STL / 3MF / STEP / OBJ) opens `showSliceDialog`, which
  slices it on the home bridge.

Either way the app returns to Files and opens the new file's sheet (preview,
Print).

## Not done

- Creality's STL downloads (`memberDownload`) are a members-only call; the app
  uses the per-printer 3MFs instead.
- MakerWorld search inside the app: not possible without its private API.
