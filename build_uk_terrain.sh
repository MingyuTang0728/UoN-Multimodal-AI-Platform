#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG ----------
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$ROOT_DIR/data"
DEM_DIR="$DATA_DIR/dem"
OUT_DIR="$ROOT_DIR/frontend/assets"
TMP_DIR="$DATA_DIR/tmp"
UK_BBOX_LAT_MIN=49
UK_BBOX_LAT_MAX=61
UK_BBOX_LON_MIN=-9
UK_BBOX_LON_MAX=2
OUT_WIDTH=8192                      # 输出宽度（高自适配）
HILLSHADE_AZ=315
HILLSHADE_ALT=45
COLOR_FILE="$DATA_DIR/color.txt"    # 彩色带
UK_GEOJSON="$DATA_DIR/uk_boundary.geojson"
# Copernicus DEM 30m（COG）公共桶（eu-central-1）
S3_BUCKET="s3://copernicus-dem-30m"
S3_PREFIX="Copernicus_DSM_COG_30"
# ---------------------------

mkdir -p "$DEM_DIR" "$OUT_DIR" "$TMP_DIR" "$DATA_DIR"

echo "==> 依赖检查"
for cmd in gdalbuildvrt gdalwarp gdal_translate gdaldem gdalinfo ogr2ogr aws wget; do
  command -v $cmd >/dev/null 2>&1 || { echo "缺少依赖：$cmd"; exit 1; }
done

# 颜色分级文件（你可以改更精细）
if [ ! -f "$COLOR_FILE" ]; then
cat > "$COLOR_FILE" <<'PAL'
-100  8  39 125
0     28 114 189
50    64 164 223
200   139 197 63
400   205 223 128
800   222 207 157
1200  205 174 137
2000  230 230 230
PAL
fi

echo "==> 下载英国边界 GeoJSON（Natural Earth 派生）"
if [ ! -f "$UK_GEOJSON" ]; then
  wget -qO "$TMP_DIR/countries.geojson" \
    https://raw.githubusercontent.com/datasets/geo-countries/master/data/countries.geojson
  # Use -where to avoid layer name differences; fallback to OGRGeoJSON if needed
  ogr2ogr -f GeoJSON "$UK_GEOJSON" "$TMP_DIR/countries.geojson" \
    -where "ADMIN='United Kingdom' OR NAME='United Kingdom'" \
  || ogr2ogr -f GeoJSON "$UK_GEOJSON" "$TMP_DIR/countries.geojson" \
    -dialect SQLITE -sql "SELECT * FROM OGRGeoJSON WHERE ADMIN='United Kingdom' OR NAME='United Kingdom'"
fi

echo "==> 从 AWS tileList 选择 UK 范围的 GLO-30 瓦片（无需登录）"
download_count=0
DEBUG=${DEBUG:-0}
log(){ [ "$DEBUG" = "1" ] && echo "[debug] $*" >&2; }

aws s3 cp --no-sign-request --region eu-central-1 \
  s3://copernicus-dem-30m/tileList.txt "$TMP_DIR/tileList.txt" >/dev/null 2>&1 || true
if [ ! -s "$TMP_DIR/tileList.txt" ]; then
  curl -fsSL https://copernicus-dem-30m.s3.amazonaws.com/tileList.txt -o "$TMP_DIR/tileList.txt" || true
fi

if [ -s "$TMP_DIR/tileList.txt" ]; then
  # 直接在 tileList 里筛选 GLO-30（10 arcsec）条目，并解析 Nxx / E|Wxxx 字段
  awk -F'_' -v minLat=$UK_BBOX_LAT_MIN -v maxLat=$UK_BBOX_LAT_MAX -v minLon=$UK_BBOX_LON_MIN -v maxLon=$UK_BBOX_LON_MAX '
    /Copernicus_DSM_COG_10_/ {
      n = $5; e = $7;
      lat = ((substr(n,1,1)=="N")?1:-1) * int(substr(n,2));
      lon = ((substr(e,1,1)=="E")?1:-1) * int(substr(e,2));
      if (lat>=minLat && lat<=maxLat && lon>=minLon && lon<=maxLon) print $0;
    }
  ' "$TMP_DIR/tileList.txt" > "$TMP_DIR/tiles_uk.txt"

  echo "   计划下载 $(wc -l < "$TMP_DIR/tiles_uk.txt" | tr -d ' ') 张瓦片…"
  while read -r TILE; do
    [ -z "$TILE" ] && continue
    KEY="s3://copernicus-dem-30m/${TILE}/${TILE}.tif"
    OUT="$DEM_DIR/${TILE}.tif"
    if [ ! -f "$OUT" ]; then
      set +e
      aws s3 cp --no-sign-request --region eu-central-1 "$KEY" "$OUT" >/dev/null 2>&1
      rc=$?
      if [ $rc -ne 0 ]; then
        # HTTPS fallback
        URL="https://copernicus-dem-30m.s3.amazonaws.com/${TILE}/${TILE}.tif"
        log "aws cp failed ($KEY), trying HTTPS: $URL"
        curl -fsSL "$URL" -o "$OUT"
        rc=$?
      fi
      set -e
      if [ $rc -eq 0 ]; then
        echo "  + $(basename "$OUT")"
        download_count=$((download_count+1))
      else
        log "failed to fetch: $TILE"
      fi
    fi
  done < "$TMP_DIR/tiles_uk.txt"
else
  echo "   未能获取 tileList.txt；将跳过自动下载。"
fi

if [ $download_count -eq 0 ]; then
  echo "!! 自动下载未取到文件。你可以："
  echo "   A) 去 Copernicus Data Space 手动下英国附近 DEM GeoTIFF 放到：$DEM_DIR"
  echo "   B) 或检查 AWS CLI 是否安装且能访问公共桶（无需账号）。"
  echo "   继续执行：脚本会使用你现有的 $DEM_DIR/*.tif 继续拼接。"
fi

echo "==> 拼接 DEM 到 VRT"
if ls "$DEM_DIR"/*.tif >/dev/null 2>&1; then
  gdalbuildvrt -overwrite "$TMP_DIR/uk_dem.vrt" "$DEM_DIR"/*.tif
else
  echo "ERROR: $DEM_DIR 下没有 .tif；请先把 DEM 放入该目录后重试。"; exit 2;
fi

echo "==> 按英国边界裁剪并投影到 EPSG:3857（Web Mercator）"
gdalwarp -overwrite -cutline "$UK_GEOJSON" -crop_to_cutline \
  -t_srs EPSG:3857 -r bilinear \
  "$TMP_DIR/uk_dem.vrt" "$TMP_DIR/uk_dem_3857.tif"

echo "==> 重采样到宽 $OUT_WIDTH（高自适配）"
gdal_translate -of GTiff -r bilinear -outsize $OUT_WIDTH 0 -ot Float32 \
  "$TMP_DIR/uk_dem_3857.tif" "$TMP_DIR/uk_dem_8192.tif"

echo "==> 生成山体阴影（Hillshade）"
gdaldem hillshade -compute_edges -az $HILLSHADE_AZ -alt $HILLSHADE_ALT \
  "$TMP_DIR/uk_dem_8192.tif" "$TMP_DIR/uk_hs_8192.tif"

echo "==> 生成彩色地形（Color relief）"
gdaldem color-relief "$TMP_DIR/uk_dem_8192.tif" "$COLOR_FILE" "$TMP_DIR/uk_color_8192.tif"

echo "==> 合成最终纹理（彩色 × 阴影）并导出 PNG"
gdal_calc.py -A "$TMP_DIR/uk_color_8192.tif" -B "$TMP_DIR/uk_hs_8192.tif" \
  --calc="clip(A*0.90 + B*0.55, 0, 255)" --type=Byte --NoDataValue=0 \
  --outfile="$TMP_DIR/uk_tex_8192.tif"
gdal_translate -of PNG "$TMP_DIR/uk_tex_8192.tif" "$OUT_DIR/uk_tex_8192.png"

echo "==> 统计真实高程范围（用于 16bit 高度图拉伸）"
MINMAX=$(gdalinfo -mm "$TMP_DIR/uk_dem_8192.tif" | awk '/Computed Min\/Max/ {print $3}' | tr -d '()')
MIN_ELEV=${MINMAX%*,*}; MAX_ELEV=${MINMAX#*,}
# 若统计失败使用合理兜底
[ -z "$MIN_ELEV" ] && MIN_ELEV=-100
[ -z "$MAX_ELEV" ] && MAX_ELEV=1500
echo "    min=$MIN_ELEV, max=$MAX_ELEV"

echo "==> 导出 16bit 高度图 PNG（记录 min/max 供前端使用）"
gdal_translate -of PNG -ot UInt16 -scale $MIN_ELEV $MAX_ELEV 0 65535 \
  "$TMP_DIR/uk_dem_8192.tif" "$OUT_DIR/uk_height_8192.png"
echo "$MIN_ELEV $MAX_ELEV" > "$OUT_DIR/uk_height_range.txt"

echo "==> 导出英国边界到 assets（挤出/遮罩用）"
cp "$UK_GEOJSON" "$OUT_DIR/uk_boundary.geojson"

echo "✅ 生成完成，文件已放到：$OUT_DIR"
ls -lh "$OUT_DIR"/uk_* | sed 's/^/   /'
echo "   - 纹理: uk_tex_8192.png"
echo "   - 高程: uk_height_8192.png  （拉伸范围写在 uk_height_range.txt）"
echo "   - 边界: uk_boundary.geojson"

# Hint: run with DEBUG=1 ./build_uk_terrain.sh to print debug logs