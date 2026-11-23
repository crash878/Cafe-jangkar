export function calculateTotals(items, discount = 0, taxEnabled = false, taxRate = 0) {
  const subtotal = (items || []).reduce((sum, item) => sum + Number(item.price || 0) * Number(item.qty || 0), 0);
  const safeDiscount = Math.min(subtotal, Math.max(0, Math.round(Number(discount) || 0)));
  const taxable = Math.max(0, subtotal - safeDiscount);
  const tax = taxEnabled ? Math.round(taxable * Math.min(100, Math.max(0, Number(taxRate) || 0)) / 100) : 0;
  return { subtotal, discount: safeDiscount, tax, total: taxable + tax };
}

export function calculateChange(received, total) {
  return Math.max(0, Math.round(Number(received) || 0) - Math.max(0, Number(total) || 0));
}

export function stockStatus(stock, minimum) {
  const qty = Number(stock) || 0;
  if (qty <= 0) return 'Habis';
  return qty <= (Number(minimum) || 0) ? 'Menipis' : 'Aman';
}

export function netSales(transaction) {
  if (!transaction || transaction.status !== 'Selesai') return 0;
  return Math.max(0, Number(transaction.subtotal ?? transaction.total ?? 0) - Number(transaction.discount || 0));
}
