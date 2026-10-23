# Railway variable classifier shared by railway_inventory.sh and breach_check.sh.
# Input: the JSON from `railway variable list --json` (any of the shapes `entries` accepts).
# Output: [{key, value}]; callers then use classify(.key; .value). Values are only inspected here,
# never emitted by the callers.
  def dbnames: ["DATABASE_URL","DATABASE_PUBLIC_URL","DATABASE_UNPOOLED_URL","DATABASE_PUBLIC_UNPOOLED_URL",
                "REDIS_URL","REDIS_PUBLIC_URL","MYSQL_URL","MYSQL_PUBLIC_URL","MONGO_URL","MONGO_PUBLIC_URL",
                "PGHOST","PGPORT","PGUSER","PGPASSWORD","PGDATABASE","PGDATA","POSTGRES_DB","POSTGRES_USER","POSTGRES_PASSWORD",
                "REDISHOST","REDISPORT","REDISUSER","REDISPASSWORD","MYSQLHOST","MYSQLPORT","MYSQLUSER","MYSQLPASSWORD","MYSQLDATABASE",
                "MYSQL_ROOT_PASSWORD","MONGOHOST","MONGOPORT","MONGOUSER","MONGOPASSWORD"];
  def bucketnames: ["BUCKET","ACCESS_KEY_ID","SECRET_ACCESS_KEY","REGION","ENDPOINT",
                    "AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","AWS_ENDPOINT_URL","AWS_S3_BUCKET_NAME","AWS_REGION","AWS_DEFAULT_REGION"];
  def classify($k; $v):
    ($v|tostring) as $s
    | if ($k|startswith("RAILWAY_")) then "railway_injected"
    elif ($k|test("^(RAILPACK_|NIXPACKS_|NO_CACHE$)")) then "build_tuning"
    elif ($s|contains("${{")) then "reference"
    elif (dbnames|index($k)) != null then "database"
    elif ($s|test("^(postgres(ql)?|mysql|mongodb(\\+srv)?|redis(s)?)://")) then "database"
    elif (bucketnames|index($k)) != null then "bucket_credential"
    elif ($s|test("storageapi\\.dev")) then "bucket_credential"
    elif ($k|test("^(NEXT_PUBLIC_|VITE_|PUBLIC_|REACT_APP_|NUXT_PUBLIC_|EXPO_PUBLIC_)")) then "public_buildtime"
    elif ($s=="") then "empty"
    else "app_secret" end;
  # normalise {K:V} | [{name,value}] | [{key,value}] | {variables:{...}}
  def entries:
    if type=="object" and has("variables") then (.variables|entries)
    elif type=="object" then to_entries
    elif type=="array" then map({key:(.name // .key // .Name), value:(.value // .Value // "")})
    else [] end;
  entries | map(select(.key|type=="string"))
