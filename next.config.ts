import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: { serverActions: { bodySizeLimit: "3mb" } },
  outputFileTracingIncludes: { "/operacional/**": ["./public/fonts/NotoSans-Regular.ttf"] },
  distDir: process.env.ECONTROLL_NEXT_DIST_DIR || ".next",
};

export default nextConfig;
