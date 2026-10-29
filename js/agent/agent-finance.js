/* Uses the existing finance engine on both platforms. Host supplies StorageManager. */
globalThis.AgentFinance = {
    summary(month) {
        if (!/^\d{4}-\d{2}$/.test(month)) throw new Error('month must be YYYY-MM.');
        PortfolioApp.loadData(); SpendingApp.loadData();
        const holdings = PortfolioApp.computeHoldings();
        return { summary: PortfolioApp.getSummary(holdings), holdings, unpriced: holdings.filter(h => !(h.currentPrice > 0)).map(h => h.ticker), spending: SpendingApp.summary(month), month };
    },
    transaction(row, deleting) {
        PortfolioApp.loadData();
        const old = PortfolioApp.transactions.find(t => t.id === row.id);
        if (!deleting && row.type === 'sell') {
            const available = PortfolioApp.computeHoldings(row.accountId).find(h => h.ticker === row.ticker)?.totalShares || 0;
            const oldQuantity = old?.type === 'sell' && old.accountId === row.accountId && old.ticker === row.ticker ? old.quantity : 0;
            if (PortfolioApp.roundShares(row.quantity) > PortfolioApp.roundShares(available + oldQuantity)) throw new Error('The account does not have enough shares/contracts to sell.');
        }
        if (old) PortfolioApp.adjustCash(old.accountId, old.type, -PortfolioApp.txnAmount(old));
        PortfolioApp.transactions = PortfolioApp.transactions.filter(t => t.id !== row.id);
        if (deleting) PortfolioApp._tombstone(row.id);
        else { PortfolioApp.transactions.push(row); PortfolioApp.adjustCash(row.accountId, row.type, PortfolioApp.txnAmount(row)); }
        const blob = StorageManager.get('portfolio') || {};
        const result = StorageManager.set('portfolio', { ...blob, accounts: PortfolioApp.accounts, transactions: PortfolioApp.transactions, tombstones: PortfolioApp.tombstones });
        if (result === false) throw new Error('Could not save this transaction.');
    }
};
