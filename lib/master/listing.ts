export const MASTER_PAGE_SIZE = 20;

export function parseMasterPage(value: unknown): number {
  if (typeof value !== "string" || !/^[1-9]\d*$/.test(value)) return 1;
  const page = Number(value);
  return Number.isSafeInteger(page) && page <= 5_001 ? page : 1;
}

export function paginateRows<T>(rows: readonly T[], page: number, pageSize = MASTER_PAGE_SIZE) {
  const safePage = Math.max(1, page);
  const start = (safePage - 1) * pageSize;
  return { rows: rows.slice(start, start + pageSize), hasNext: rows.length > start + pageSize };
}

export function filterBranches<T extends { code: string; name: string; cnpj: string | null; address: string | null; status: string }>(
  rows: readonly T[],
  search: string | null,
  status: string | null,
): T[] {
  const query = search?.trim().toLocaleLowerCase("pt-BR") ?? "";
  return rows.filter((branch) => {
    if (status && branch.status !== status) return false;
    if (!query) return true;
    return [branch.code, branch.name, branch.cnpj ?? "", branch.address ?? ""]
      .some((value) => value.toLocaleLowerCase("pt-BR").includes(query));
  });
}
