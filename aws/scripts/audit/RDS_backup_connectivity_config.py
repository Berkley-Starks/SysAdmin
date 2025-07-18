import boto3
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.common.exceptions import TimeoutException
import time
import os
from datetime import datetime
import base64
import sys
import urllib.parse

# Determine mode and filter
mode = "all"
filter_text = None

if len(sys.argv) > 1:
    if sys.argv[1].lower() in ["all", "aws", "gmail"]:
        mode = sys.argv[1].lower()
        if len(sys.argv) > 2:
            filter_text = sys.argv[2].lower()
    else:
        filter_text = sys.argv[1].lower()

print("[OK] Mode selected: {}".format(mode.upper()))
if filter_text:
    print("[OK] Filter applied: {}".format(filter_text))

regions = [
    "us-east-1",
    "us-east-2",
    "us-west-1",
    "us-west-2",
    "ap-northeast-1",
    "ap-northeast-2",
    "eu-central-1",
    "eu-west-1"
]

tabs = [
    ("maintenance-and-backups", "maintenance_and_backups"),
    ("configuration", "configuration"),
    ("connectivity", "connectivity")
]

parent_dir = "screenshots"
os.makedirs(parent_dir, exist_ok=True)

timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
output_dir = os.path.join(parent_dir, timestamp)
os.makedirs(output_dir, exist_ok=True)

print("[OK] Screenshots will be saved in: {}".format(output_dir))

chrome_options = Options()
chrome_options.add_argument("--start-maximized")
chrome_options.add_argument("--window-size=1920,1080")
chrome_options.add_argument(
    "user-data-dir=" + os.path.expanduser("~/selenium-chrome-okta")
)

# Launch Chrome for login
print("[INFO] A Chrome window will open for manual login.")
driver = webdriver.Chrome(options=chrome_options)

print("[INFO] Please log into AWS Console AND Gmail in the same window.")
print("[INFO] Make sure you see the AWS RDS Console homepage and your Gmail inbox.")
input("[OK] Once logged into both, press Enter here to continue...")
driver.quit()

for region in regions:
    print("\n[INFO] Discovering RDS instances and clusters in {}...".format(region))
    rds_client = boto3.client("rds", region_name=region)

    db_identifiers = []

    # Get DB instances
    paginator_instances = rds_client.get_paginator("describe_db_instances")
    for page in paginator_instances.paginate():
        for db in page["DBInstances"]:
            db_identifiers.append(db["DBInstanceIdentifier"])

    # Get DB clusters
    paginator_clusters = rds_client.get_paginator("describe_db_clusters")
    for page in paginator_clusters.paginate():
        for cluster in page["DBClusters"]:
            db_identifiers.append(cluster["DBClusterIdentifier"])

    # Apply filter if provided
    if filter_text:
        db_identifiers = [i for i in db_identifiers if filter_text in i.lower()]

    if not db_identifiers:
        print("[WARN] No matching databases or clusters found in {}. Skipping.".format(region))
        continue

    print("[OK] Resources to process: {}".format(", ".join(db_identifiers)))

    for db_name in db_identifiers:
        is_cluster = "cluster" in db_name.lower()
        safe_db_name = db_name.replace("/", "_").replace(":", "_")

        # AWS Screenshots
        if mode in ["all", "aws"]:
            for tab_path, tab_suffix in tabs:
                url = (
                    f"https://{region}.console.aws.amazon.com/rds/home?"
                    f"region={region}#database:id={db_name};"
                    f"is-cluster={'true' if is_cluster else 'false'};"
                    f"tab={tab_path}"
                )

                print("\n[INFO] Opening Chrome window for RDS: {} - {}".format(db_name, tab_suffix))
                driver = webdriver.Chrome(options=chrome_options)

                print("[INFO] Navigating to: {}".format(url))
                driver.get(url)

                try:
                    WebDriverWait(driver, 30).until(
                        lambda d: d.find_element("tag name", "body")
                    )
                    print("[OK] Page loaded.")
                except Exception as e:
                    print("[WARN] Page did not load properly for {}: {}".format(db_name, e))

                time.sleep(10)

                # Remove overlays and inject URL banner
                try:
                    driver.execute_script("""
                        const elements = document.querySelectorAll('*');
                        for (const el of elements) {
                          const style = getComputedStyle(el);
                          if (style.position === 'fixed' || style.position === 'sticky') {
                            el.style.display = 'none';
                          }
                        }
                        const existing = document.getElementById('url-banner');
                        if (!existing) {
                            const banner = document.createElement('div');
                            banner.id = 'url-banner';
                            banner.style.position = 'fixed';
                            banner.style.top = '0';
                            banner.style.left = '0';
                            banner.style.width = '100%';
                            banner.style.backgroundColor = 'white';
                            banner.style.color = 'black';
                            banner.style.fontSize = '14px';
                            banner.style.fontFamily = 'monospace';
                            banner.style.padding = '4px';
                            banner.style.zIndex = '999999';
                            banner.style.borderBottom = '1px solid #ccc';
                            banner.innerText = window.location.href;
                            document.body.appendChild(banner);
                        }
                    """)
                    print("[OK] Removed overlays and added URL banner.")
                except Exception as e:
                    print("[WARN] Could not remove overlays or inject URL banner: {}".format(e))

                filename = f"{safe_db_name}_{region}_{tab_suffix}.png"
                full_path = os.path.join(output_dir, filename)

                try:
                    screenshot = driver.execute_cdp_cmd("Page.captureScreenshot", {
                        "format": "png",
                        "captureBeyondViewport": True,
                        "fromSurface": True
                    })
                    with open(full_path, "wb") as f:
                        f.write(base64.b64decode(screenshot["data"]))
                    print("[OK] Saved full-page screenshot: {}".format(full_path))
                except Exception as e:
                    print("[WARN] Could not save full-page screenshot: {}".format(e))

                driver.quit()

        # Gmail Screenshot
        if mode in ["all", "gmail"]:
            print("[INFO] Preparing Gmail search URL for {}".format(db_name))
            quoted_db_name = urllib.parse.quote(f'"{db_name}"')
            gmail_url = (
                "https://mail.google.com/mail/u/0/#search/"
                "%22RDS+Notification+Message%22+" + quoted_db_name
            )

            print("[INFO] Opening Chrome window for Gmail search.")
            driver = webdriver.Chrome(options=chrome_options)

            print("[INFO] Navigating to Gmail URL: {}".format(gmail_url))
            try:
                driver.set_page_load_timeout(20)
                driver.get(gmail_url)
            except TimeoutException:
                print("[WARN] Gmail page load timeout. Proceeding anyway...")

            # Wait until body exists
            try:
                WebDriverWait(driver, 10).until(
                    lambda d: d.find_element(By.TAG_NAME, "body")
                )
            except Exception as e:
                print("[WARN] Gmail page did not load body tag: {}".format(e))
                driver.quit()
                continue

            # Wait for results or no-results message
            print("[INFO] Waiting for search results or no-results message...")
            try:
                WebDriverWait(driver, 30).until(
                    lambda d: (
                        d.find_elements(By.CSS_SELECTOR, "table.F.cf.zt tr") or
                        "No messages matched your search" in d.page_source
                    )
                )
            except Exception:
                print("[WARN] Timeout waiting for Gmail search results.")
                driver.quit()
                continue

            # Check for no messages
            if "No messages matched your search" in driver.page_source:
                print("[INFO] No matching Gmail messages found. Skipping screenshot.")
                driver.quit()
                continue

            print("[OK] Gmail search results found.")

            # Click first email
            try:
                first_email = driver.find_element(By.CSS_SELECTOR, "table.F.cf.zt tr")
                first_email.click()
                print("[OK] Clicked first email to open preview.")
                time.sleep(5)
            except Exception as e:
                print("[WARN] Could not click first email: {}".format(e))

            # Remove overlays and inject URL banner
            try:
                driver.execute_script("""
                    const elements = document.querySelectorAll('*');
                    for (const el of elements) {
                      const style = getComputedStyle(el);
                      if (style.position === 'fixed' || style.position === 'sticky') {
                        el.style.display = 'none';
                      }
                    }
                    const existing = document.getElementById('url-banner');
                    if (!existing) {
                        const banner = document.createElement('div');
                        banner.id = 'url-banner';
                        banner.style.position = 'fixed';
                        banner.style.top = '0';
                        banner.style.left = '0';
                        banner.style.width = '100%';
                        banner.style.backgroundColor = 'white';
                        banner.style.color = 'black';
                        banner.style.fontSize = '14px';
                        banner.style.fontFamily = 'monospace';
                        banner.style.padding = '4px';
                        banner.style.zIndex = '999999';
                        banner.style.borderBottom = '1px solid #ccc';
                        banner.innerText = window.location.href;
                        document.body.appendChild(banner);
                    }
                """)
                print("[OK] Removed overlays and added URL banner.")
            except Exception as e:
                print("[WARN] Could not remove overlays or inject URL banner: {}".format(e))

            gmail_filename = f"{safe_db_name}_{region}_gmail.png"
            gmail_path = os.path.join(output_dir, gmail_filename)

            try:
                screenshot = driver.execute_cdp_cmd("Page.captureScreenshot", {
                    "format": "png",
                    "captureBeyondViewport": True,
                    "fromSurface": True
                })
                with open(gmail_path, "wb") as f:
                    f.write(base64.b64decode(screenshot["data"]))
                print("[OK] Saved Gmail screenshot: {}".format(gmail_path))
            except Exception as e:
                print("[WARN] Could not save Gmail screenshot: {}".format(e))

            driver.quit()

print("\n[DONE] All screenshots captured successfully.")
